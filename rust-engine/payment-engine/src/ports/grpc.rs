use rust_decimal::prelude::ToPrimitive;
use std::collections::HashMap;
use tonic::{Request, Response, Status};
use tracing::{error, info, info_span, Instrument};
use uuid::Uuid;

use ussd_kernel_common::v1::common::{
    Error as ProtoError, ErrorCode, HealthRequest, HealthResponse, Money as ProtoMoney,
};
use ussd_kernel_common::v1::common::health_response::ServingStatus;
use ussd_kernel_common::v1::payment::payment_engine_server::PaymentEngine;
use ussd_kernel_common::v1::payment::{
    GetPaymentStatusRequest, GetPaymentStatusResponse, InitiatePaymentRequest,
    InitiatePaymentResponse, MobileMoneyProvider as ProtoProvider, PaymentStatus as ProtoStatus,
    ProcessCallbackRequest, ProcessCallbackResponse,
};

use crate::application::callback::{ProcessCallbackCommand, ProcessCallbackHandler};
use crate::application::initiate::{InitiatePaymentCommand, InitiatePaymentHandler, InitiateResult};
use crate::domain::error::DomainError;
use crate::domain::payment::PaymentStatus;
use crate::domain::provider::{MobileMoneyProvider, ProviderStatus};
use crate::infrastructure::postgres::PgPaymentRepository;

#[derive(Debug, Clone)]
pub struct PaymentGrpcServer {
    pub initiate_handler: InitiatePaymentHandler,
    pub callback_handler: ProcessCallbackHandler,
    pub payment_repo: PgPaymentRepository,
}

impl PaymentGrpcServer {
    fn map_domain_error(&self, e: DomainError, trace_id: &str) -> (Status, Option<ProtoError>) {
        let (code, proto_code) = match &e {
            DomainError::InvalidPhoneNumber(_)
            | DomainError::InvalidAmount(_)
            | DomainError::InvalidReference(_) => {
                (Status::invalid_argument(e.to_string()), ErrorCode::InvalidArgument)
            }
            DomainError::ProviderError(_) => (
                Status::failed_precondition(e.to_string()),
                ErrorCode::PaymentProviderError,
            ),
            DomainError::IdempotencyViolation => {
                (Status::already_exists(e.to_string()), ErrorCode::IdempotencyConflict)
            }
            DomainError::NotFound(_) => (Status::not_found(e.to_string()), ErrorCode::NotFound),
            DomainError::InvalidStatusTransition { from: _, to: _ } => (
                Status::failed_precondition(e.to_string()),
                ErrorCode::FailedPrecondition,
            ),
            DomainError::DatabaseError(_) => {
                (Status::internal(e.to_string()), ErrorCode::Internal)
            }
        };

        let proto_error = ProtoError {
            code: proto_code as i32,
            message: e.to_string(),
            details: {
                let mut m = HashMap::new();
                m.insert("trace_id".to_string(), trace_id.to_string());
                m
            },
            trace_id: trace_id.to_string(),
            grpc_code: code.code() as i32,
        };

        (code, Some(proto_error))
    }
}

fn map_proto_provider(provider: i32) -> Result<MobileMoneyProvider, Status> {
    match ProtoProvider::try_from(provider) {
        Ok(ProtoProvider::Ecocash) => Ok(MobileMoneyProvider::EcoCash),
        Ok(ProtoProvider::Onemoney) => Ok(MobileMoneyProvider::OneMoney),
        Ok(ProtoProvider::Telecash) => Ok(MobileMoneyProvider::Telecash),
        _ => Err(Status::invalid_argument(format!(
            "Unsupported provider: {}",
            provider
        ))),
    }
}

fn map_domain_status(status: PaymentStatus) -> i32 {
    match status {
        PaymentStatus::Pending => ProtoStatus::PaymentPending as i32,
        PaymentStatus::Processing => ProtoStatus::PaymentProcessing as i32,
        PaymentStatus::Completed => ProtoStatus::PaymentCompleted as i32,
        PaymentStatus::Failed => ProtoStatus::PaymentFailed as i32,
        PaymentStatus::Cancelled => ProtoStatus::PaymentCancelled as i32,
        PaymentStatus::Refunded => ProtoStatus::PaymentRefunded as i32,
    }
}

fn map_proto_money(amount: &rust_decimal::Decimal, currency: &str) -> Option<ProtoMoney> {
    Some(ProtoMoney {
        currency_code: currency.to_string(),
        amount_cents: (amount * rust_decimal::Decimal::new(100, 0))
            .to_i64()
            .unwrap_or(0),
        currency: 0,
    })
}

fn map_callback_status(status: i32) -> Result<ProviderStatus, Status> {
    use ussd_kernel_common::v1::payment::process_callback_request::CallbackStatus;
    match CallbackStatus::try_from(status) {
        Ok(CallbackStatus::Success) => Ok(ProviderStatus::Completed),
        Ok(CallbackStatus::Failed) => Ok(ProviderStatus::Failed),
        Ok(CallbackStatus::Timeout) => Ok(ProviderStatus::Failed),
        Ok(CallbackStatus::Cancelled) => Ok(ProviderStatus::Cancelled),
        Ok(CallbackStatus::Pending) => Ok(ProviderStatus::Pending),
        _ => Err(Status::invalid_argument(format!(
            "Unknown callback status: {}",
            status
        ))),
    }
}

fn extract_trace_id<T>(req: &Request<T>) -> String {
    req.metadata()
        .get("x-trace-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string()
}

#[tonic::async_trait]
impl PaymentEngine for PaymentGrpcServer {
    async fn initiate_payment(
        &self,
        request: Request<InitiatePaymentRequest>,
    ) -> Result<Response<InitiatePaymentResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("initiate_payment"));

        async {
            info!(trace_id = %trace_id, "Processing initiate_payment request");
            let req = request.into_inner();

            let tenant_id = parse_uuid(&req.tenant_id)?;
            let payment_id = parse_uuid(&req.payment_id).unwrap_or_else(|_| Uuid::new_v4());
            let idempotency_key = req
                .idempotency_key
                .map(|k| k.value)
                .unwrap_or_else(|| payment_id.to_string());
            let provider = map_proto_provider(req.provider)?;
            let provider_label = format!("{:?}", provider).to_lowercase();
            let amount = proto_money_to_decimal(req.amount.as_ref())?;
            let currency = req
                .amount
                .as_ref()
                .map(|m| m.currency_code.clone())
                .unwrap_or_else(|| "USD".to_string());
            let currency_for_error = currency.clone();

            let cmd = InitiatePaymentCommand {
                payment_id,
                tenant_id,
                idempotency_key,
                provider,
                phone_number: req.phone_number,
                amount,
                currency,
                reference: req.reference,
                description: req.description,
            };

            let start = std::time::Instant::now();
            match self.initiate_handler.handle(cmd).await {
                Ok(result) => {
                    let duration = start.elapsed().as_secs_f64();
                    ussd_kernel_common::telemetry::record_metric(
                        "payment_initiated_total",
                        1.0,
                        &[("provider", &provider_label), ("status", "success")],
                    );
                    ussd_kernel_common::telemetry::record_metric(
                        "provider_request_duration_seconds",
                        duration,
                        &[("provider", &provider_label)],
                    );
                    info!(trace_id = %trace_id, payment_id = %payment_id, "initiate_payment succeeded");
                    Ok(Response::new(build_initiate_response(result, None)))
                }
                Err(e) => {
                    let duration = start.elapsed().as_secs_f64();
                    error!(error = %e, trace_id = %trace_id, "initiate_payment failed");
                    ussd_kernel_common::telemetry::record_metric(
                        "payment_initiated_total",
                        1.0,
                        &[("provider", &provider_label), ("status", "failed")],
                    );
                    ussd_kernel_common::telemetry::record_metric(
                        "provider_request_duration_seconds",
                        duration,
                        &[("provider", &provider_label)],
                    );
                    let (status, proto_err) = self.map_domain_error(e, &trace_id);
                    let _resp = InitiatePaymentResponse {
                        payment_id: payment_id.to_string(),
                        status: 0,
                        provider_reference: "".to_string(),
                        initiated_at: None,
                        estimated_completion_seconds: 0,
                        message: "Payment initiation failed".to_string(),
                        error: proto_err,
                        total_amount: map_proto_money(&amount, &currency_for_error),
                        fee_breakdown: None,
                        ledger_transaction_id: "".to_string(),
                    };
                    Err(status)
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_payment_status(
        &self,
        request: Request<GetPaymentStatusRequest>,
    ) -> Result<Response<GetPaymentStatusResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_payment_status"));

        async {
            info!(trace_id = %trace_id, "Processing get_payment_status request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let payment_id = parse_uuid(&req.payment_id)?;

            match self.payment_repo.get_payment_by_id(tenant_id, payment_id).await {
                Ok(Some(payment)) => Ok(Response::new(GetPaymentStatusResponse {
                    payment_id: payment.payment_id.to_string(),
                    status: map_domain_status(payment.status),
                    previous_status: 0,
                    amount: map_proto_money(&payment.amount, &payment.currency),
                    provider_reference: payment.provider_reference.unwrap_or_default(),
                    initiated_at: Some(chrono_to_prost(payment.initiated_at)),
                    completed_at: payment.completed_at.map(chrono_to_prost),
                    failure_reason: payment.failure_reason.unwrap_or_default(),
                    retry_count: 0,
                    error: None,
                    ledger_transaction_id: "".to_string(),
                })),
                Ok(None) => {
                    let (_, proto_err) =
                        self.map_domain_error(DomainError::NotFound(req.payment_id), &trace_id);
                    Ok(Response::new(GetPaymentStatusResponse {
                        payment_id: payment_id.to_string(),
                        error: proto_err,
                        ..Default::default()
                    }))
                }
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(GetPaymentStatusResponse {
                        payment_id: payment_id.to_string(),
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn process_callback(
        &self,
        request: Request<ProcessCallbackRequest>,
    ) -> Result<Response<ProcessCallbackResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("process_callback"));

        async {
            info!(trace_id = %trace_id, "Processing process_callback request");
            let req = request.into_inner();
            let payment_id = if req.payment_id.is_empty() {
                None
            } else {
                Some(parse_uuid(&req.payment_id)?)
            };
            let provider_status = map_callback_status(req.status)?;

            let payment = match self
                .payment_repo
                .get_payment_by_provider_ref(None, &req.provider_reference)
                .await
            {
                Ok(Some(p)) => p,
                Ok(None) => {
                    if let Some(pid) = payment_id {
                        match self.payment_repo.get_payment_by_id_untenantized(pid).await {
                            Ok(Some(p)) => p,
                            Ok(None) | Err(_) => {
                                return Ok(Response::new(ProcessCallbackResponse {
                                    accepted: false,
                                    message: "Payment not found".to_string(),
                                    payment_id: pid.to_string(),
                                    new_status: 0,
                                    error: Some(ProtoError {
                                        code: ErrorCode::NotFound as i32,
                                        message: "Payment not found".to_string(),
                                        details: Default::default(),
                                        trace_id: trace_id.clone(),
                                        grpc_code: tonic::Code::NotFound as i32,
                                    }),
                                }));
                            }
                        }
                    } else {
                        return Ok(Response::new(ProcessCallbackResponse {
                            accepted: false,
                            message: "Payment not found".to_string(),
                            payment_id: "".to_string(),
                            new_status: 0,
                            error: Some(ProtoError {
                                code: ErrorCode::NotFound as i32,
                                message: "Payment not found".to_string(),
                                details: Default::default(),
                                trace_id: trace_id.clone(),
                                grpc_code: tonic::Code::NotFound as i32,
                            }),
                        }));
                    }
                }
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    return Ok(Response::new(ProcessCallbackResponse {
                        accepted: false,
                        message: "Database error".to_string(),
                        payment_id: payment_id.map(|u| u.to_string()).unwrap_or_default(),
                        new_status: 0,
                        error: proto_err,
                    }));
                }
            };

            let cmd = ProcessCallbackCommand {
                tenant_id: payment.tenant_id,
                provider_reference: req.provider_reference,
                payment_id: Some(payment.payment_id),
                status: provider_status,
                signature: req.signature,
                raw_payload: req.raw_payload,
            };

            match self.callback_handler.handle(cmd).await {
                Ok(result) => Ok(Response::new(ProcessCallbackResponse {
                    accepted: result.accepted,
                    message: "Callback processed".to_string(),
                    payment_id: result.payment.payment_id.to_string(),
                    new_status: map_domain_status(result.payment.status),
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, trace_id = %trace_id, "process_callback failed");
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(ProcessCallbackResponse {
                        accepted: false,
                        message: "Callback processing failed".to_string(),
                        payment_id: payment.payment_id.to_string(),
                        new_status: 0,
                        error: proto_err,
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn health(
        &self,
        request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("health"));
        async {
            Ok(Response::new(HealthResponse {
                status: ServingStatus::Serving as i32,
                version: env!("CARGO_PKG_VERSION").to_string(),
                timestamp: Some(prost_types::Timestamp::from(std::time::SystemTime::now())),
                dependencies: HashMap::new(),
                metadata: HashMap::new(),
            }))
        }
        .instrument(span)
        .await
    }

    async fn preview_payment(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::PreviewPaymentRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::PreviewPaymentResponse>, Status> {
        Err(Status::unimplemented("preview_payment not implemented"))
    }

    async fn bulk_initiate_payment(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::BulkInitiatePaymentRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::common::BatchOperationResult>, Status> {
        Err(Status::unimplemented("bulk_initiate_payment not implemented"))
    }

    async fn initiate_disbursement(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::InitiateDisbursementRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::InitiateDisbursementResponse>, Status> {
        Err(Status::unimplemented("initiate_disbursement not implemented"))
    }

    async fn bulk_initiate_disbursement(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::BulkInitiateDisbursementRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::common::BatchOperationResult>, Status> {
        Err(Status::unimplemented(
            "bulk_initiate_disbursement not implemented",
        ))
    }

    async fn get_payment_details(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetPaymentDetailsRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::GetPaymentDetailsResponse>, Status> {
        Err(Status::unimplemented("get_payment_details not implemented"))
    }

    async fn refund_payment(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::RefundPaymentRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::RefundPaymentResponse>, Status> {
        Err(Status::unimplemented("refund_payment not implemented"))
    }

    async fn reverse_payment(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ReversePaymentRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ReversePaymentResponse>, Status> {
        Err(Status::unimplemented("reverse_payment not implemented"))
    }

    async fn list_payments(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ListPaymentsRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ListPaymentsResponse>, Status> {
        Err(Status::unimplemented("list_payments not implemented"))
    }

    async fn get_payment_analytics(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetPaymentAnalyticsRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::GetPaymentAnalyticsResponse>, Status> {
        Err(Status::unimplemented("get_payment_analytics not implemented"))
    }

    async fn validate_phone_number(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ValidatePhoneNumberRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ValidatePhoneNumberResponse>, Status> {
        Err(Status::unimplemented("validate_phone_number not implemented"))
    }

    async fn get_provider_balance(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetProviderBalanceRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::GetProviderBalanceResponse>, Status> {
        Err(Status::unimplemented("get_provider_balance not implemented"))
    }

    async fn get_provider_capabilities(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetProviderCapabilitiesRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::GetProviderCapabilitiesResponse>, Status>
    {
        Err(Status::unimplemented(
            "get_provider_capabilities not implemented",
        ))
    }

    async fn report_dispute(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ReportDisputeRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ReportDisputeResponse>, Status> {
        Err(Status::unimplemented("report_dispute not implemented"))
    }

    async fn update_dispute(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::UpdateDisputeRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::Dispute>, Status> {
        Err(Status::unimplemented("update_dispute not implemented"))
    }

    async fn upload_dispute_evidence(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::UploadDisputeEvidenceRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::UploadDisputeEvidenceResponse>, Status> {
        Err(Status::unimplemented(
            "upload_dispute_evidence not implemented",
        ))
    }

    async fn get_dispute_status(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetDisputeStatusRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::Dispute>, Status> {
        Err(Status::unimplemented("get_dispute_status not implemented"))
    }

    async fn list_disputes(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ListDisputesRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ListDisputesResponse>, Status> {
        Err(Status::unimplemented("list_disputes not implemented"))
    }

    async fn generate_settlement_file(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GenerateSettlementFileRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::GenerateSettlementFileResponse>, Status>
    {
        Err(Status::unimplemented(
            "generate_settlement_file not implemented",
        ))
    }

    async fn get_settlement_file(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::GetSettlementFileRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::SettlementFile>, Status> {
        Err(Status::unimplemented("get_settlement_file not implemented"))
    }

    async fn list_settlement_files(
        &self,
        _request: Request<ussd_kernel_common::v1::payment::ListSettlementFilesRequest>,
    ) -> Result<Response<ussd_kernel_common::v1::payment::ListSettlementFilesResponse>, Status> {
        Err(Status::unimplemented("list_settlement_files not implemented"))
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, Status> {
    Uuid::parse_str(s).map_err(|_| Status::invalid_argument(format!("Invalid UUID: {}", s)))
}

fn proto_money_to_decimal(money: Option<&ProtoMoney>) -> Result<rust_decimal::Decimal, Status> {
    money
        .map(|m| rust_decimal::Decimal::new(m.amount_cents, 2))
        .ok_or_else(|| Status::invalid_argument("Amount is required"))
}

fn chrono_to_prost(dt: chrono::DateTime<chrono::Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: dt.timestamp(),
        nanos: dt.timestamp_subsec_nanos() as i32,
    }
}

fn build_initiate_response(result: InitiateResult, error: Option<ProtoError>) -> InitiatePaymentResponse {
    InitiatePaymentResponse {
        payment_id: result.payment.payment_id.to_string(),
        status: map_domain_status(result.payment.status),
        provider_reference: result.provider_reference.unwrap_or_default(),
        initiated_at: Some(chrono_to_prost(result.payment.initiated_at)),
        estimated_completion_seconds: 30,
        message: "Payment initiated".to_string(),
        error,
        total_amount: map_proto_money(&result.payment.amount, &result.payment.currency),
        fee_breakdown: None,
        ledger_transaction_id: "".to_string(),
    }
}
