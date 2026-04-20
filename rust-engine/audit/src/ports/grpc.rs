use std::pin::Pin;

use futures::Stream;
use tonic::{Request, Response, Status};
use tracing::{error, info, info_span, Instrument};

use ussd_kernel_common::v1::audit::audit_service_server::AuditService;
use ussd_kernel_common::v1::audit::{
    AuditEntry, ExportAuditReportRequest, ExportAuditReportResponse, GetAuditReportRequest,
    GetAuditReportResponse, GetAuditTrailRequest, GetLedgerChecksumRequest,
    GetLedgerChecksumResponse, GetMerkleProofRequest, GetMerkleProofResponse,
    GetSigningKeysRequest, GetSigningKeysResponse, TransactionChainReport,
    VerifyBatchIntegrityRequest, VerifyBatchIntegrityResponse, VerifyTransactionChainRequest,
};
use ussd_kernel_common::v1::common::{
    health_response::ServingStatus, HealthRequest, HealthResponse,
};

use crate::application::audit::AuditHandler;

pub struct AuditGrpcServer {
    handler: AuditHandler,
}

impl AuditGrpcServer {
    pub fn new(handler: AuditHandler) -> Self {
        Self { handler }
    }
}

#[tonic::async_trait]
impl AuditService for AuditGrpcServer {
    async fn get_merkle_proof(
        &self,
        request: Request<GetMerkleProofRequest>,
    ) -> Result<Response<GetMerkleProofResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_merkle_proof called");

            let (target_id, event_id, sequence_number) = match &req.target {
                Some(ussd_kernel_common::v1::audit::get_merkle_proof_request::Target::TransactionId(id)) => {
                    (Some(id.clone()), None, None)
                }
                Some(ussd_kernel_common::v1::audit::get_merkle_proof_request::Target::EventId(id)) => {
                    (None, Some(id.clone()), None)
                }
                Some(ussd_kernel_common::v1::audit::get_merkle_proof_request::Target::SequenceNumber(seq)) => {
                    (None, None, Some(*seq))
                }
                _ => (None, None, None),
            };

            match self
                .handler
                .get_merkle_proof(target_id.clone(), event_id, sequence_number)
                .await
            {
                Ok(result) => {
                    let target_id_str = target_id.unwrap_or_else(|| result.event_id.clone());
                    Ok(Response::new(GetMerkleProofResponse {
                        event_id: result.event_id,
                        merkle_root: result.merkle_root.into(),
                        proof_hashes: result.proof_hashes,
                        computed_at: Some(to_prost_timestamp(result.computed_at)),
                        valid: result.valid,
                        error: None,
                        target_id: target_id_str,
                        sequence_number: result.sequence_number,
                        block_number: result.sequence_number,
                        signature: result.signature,
                        signer_key_id: result.signer_key_id,
                    }))
                }
                Err(e) => {
                    error!(error = %e, "get_merkle_proof failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_ledger_checksum(
        &self,
        request: Request<GetLedgerChecksumRequest>,
    ) -> Result<Response<GetLedgerChecksumResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_ledger_checksum called");
            let from = req
                .from_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(1));
            let to = req
                .to_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(|| chrono::Utc::now());

            match self.handler.get_ledger_checksum(from, to).await {
                Ok(result) => Ok(Response::new(GetLedgerChecksumResponse {
                    merkle_root: result.merkle_root.into(),
                    event_count: result.event_count,
                    computed_at: Some(to_prost_timestamp(result.computed_at)),
                    checksum_id: result.checksum_id,
                    latest_sequence_number: result.latest_sequence_number,
                    total_events: result.total_events,
                    signature: result.signature,
                    signer_key_id: result.signer_key_id,
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "get_ledger_checksum failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn verify_batch_integrity(
        &self,
        request: Request<VerifyBatchIntegrityRequest>,
    ) -> Result<Response<VerifyBatchIntegrityResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("verify_batch_integrity called");
            let expected_root = if req.expected_root.is_empty() {
                None
            } else {
                Some(hex::encode(&req.expected_root))
            };

            match self
                .handler
                .verify_batch_integrity(req.start_event_id, req.end_event_id, expected_root)
                .await
            {
                Ok(result) => Ok(Response::new(VerifyBatchIntegrityResponse {
                    valid: result.valid,
                    computed_root: result.computed_root,
                    error: None,
                    period_start: result.period_start.map(to_prost_timestamp),
                    period_end: result.period_end.map(to_prost_timestamp),
                    total_transactions: result.total_transactions,
                    verified_transactions: result.verified_transactions,
                    failed_transactions: result.failed_transactions,
                    is_fully_valid: result.is_fully_valid,
                    previous_batch_hash: result.previous_batch_hash.unwrap_or_default(),
                    violations: result
                        .violations
                        .into_iter()
                        .map(|v| ussd_kernel_common::v1::audit::IntegrityViolation {
                            transaction_id: v.transaction_id,
                            expected_hash: v.expected_hash,
                            actual_hash: v.actual_hash,
                            violation_type: v.violation_type,
                        })
                        .collect(),
                })),
                Err(e) => {
                    error!(error = %e, "verify_batch_integrity failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    type StreamAuditEventsStream =
        Pin<Box<dyn Stream<Item = Result<ussd_kernel_common::v1::common::EventEnvelope, Status>> + Send>>;

    async fn stream_audit_events(
        &self,
        request: Request<ussd_kernel_common::v1::audit::StreamAuditEventsRequest>,
    ) -> Result<Response<Self::StreamAuditEventsStream>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("stream_audit_events called");
            let from = req
                .from_timestamp
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(1)))
                .unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(1));

            match self.handler.stream_audit_events(from, req.event_types).await {
                Ok(events) => {
                    let stream = tokio_stream::iter(events.into_iter().map(|e| {
                        Ok(ussd_kernel_common::v1::common::EventEnvelope {
                            event_id: e.event_id.to_string(),
                            event_type: e.event_type,
                            aggregate_type: "EVENT".to_string(),
                            aggregate_id: e.event_id.to_string(),
                            version: e.sequence_number,
                            payload: Some(
                                serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(
                                    &e.payload.to_string(),
                                )
                                .ok()
                                .and_then(|m| {
                                    let mut struct_ = prost_types::Struct::default();
                                    struct_.fields.extend(
                                        m.into_iter()
                                            .map(|(k, v)| (k, json_to_prost_value(v))),
                                    );
                                    Some(struct_)
                                })
                                .unwrap_or_default(),
                            ),
                            context: None,
                            audit: None,
                            occurred_at: Some(to_prost_timestamp(e.occurred_at)),
                            correlation_id: String::new(),
                            causation_id: String::new(),
                            idempotency_key: String::new(),
                            record_hash: e.record_hash,
                            previous_hash: e.previous_hash.unwrap_or_default(),
                            tracing: None,
                        })
                    }));
                    Ok(Response::new(Box::pin(stream) as Self::StreamAuditEventsStream))
                }
                Err(e) => {
                    error!(error = %e, "stream_audit_events failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn verify_transaction_chain(
        &self,
        request: Request<VerifyTransactionChainRequest>,
    ) -> Result<Response<TransactionChainReport>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("verify_transaction_chain called");
            match self
                .handler
                .verify_transaction_chain(req.transaction_id, req.max_depth)
                .await
            {
                Ok(result) => Ok(Response::new(TransactionChainReport {
                    start_transaction_id: result.start_transaction_id,
                    is_valid: result.is_valid,
                    chain_length: result.chain_length,
                    broken_at_transaction_id: result.broken_at_transaction_id.unwrap_or_default(),
                    expected_hash: result.expected_hash.unwrap_or_default(),
                    actual_hash: result.actual_hash.unwrap_or_default(),
                })),
                Err(e) => {
                    error!(error = %e, "verify_transaction_chain failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    type GetAuditTrailStream =
        Pin<Box<dyn Stream<Item = Result<AuditEntry, Status>> + Send>>;

    async fn get_audit_trail(
        &self,
        request: Request<GetAuditTrailRequest>,
    ) -> Result<Response<Self::GetAuditTrailStream>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_audit_trail called");
            let page_size = req.pagination.as_ref().map(|p| p.page_size).unwrap_or(50);
            let page_token = req
                .pagination
                .as_ref()
                .map(|p| p.page_token.clone())
                .unwrap_or_default();

            match self
                .handler
                .get_audit_trail(req.record_id, req.table_name, page_size, page_token)
                .await
            {
                Ok(records) => {
                    let stream = tokio_stream::iter(records.into_iter().map(|r| {
                        Ok(AuditEntry {
                            audit_id: r.audit_id,
                            event_type: r.event_type,
                            action: r.action,
                            actor: None,
                            old_data: r.old_data.map(|v| {
                                let mut s = prost_types::Struct::default();
                                s.fields.extend(
                                    serde_json::from_value::<serde_json::Map<String, serde_json::Value>>(v)
                                        .unwrap_or_default()
                                        .into_iter()
                                        .map(|(k, v)| (k, json_to_prost_value(v))),
                                );
                                s
                            }),
                            new_data: r.new_data.map(|v| {
                                let mut s = prost_types::Struct::default();
                                s.fields.extend(
                                    serde_json::from_value::<serde_json::Map<String, serde_json::Value>>(v)
                                        .unwrap_or_default()
                                        .into_iter()
                                        .map(|(k, v)| (k, json_to_prost_value(v))),
                                );
                                s
                            }),
                            timestamp: Some(to_prost_timestamp(r.timestamp)),
                            record_hash: r.record_hash,
                            previous_hash: r.previous_hash.unwrap_or_default(),
                        })
                    }));
                    Ok(Response::new(Box::pin(stream) as Self::GetAuditTrailStream))
                }
                Err(e) => {
                    error!(error = %e, "get_audit_trail failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_audit_report(
        &self,
        request: Request<GetAuditReportRequest>,
    ) -> Result<Response<GetAuditReportResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("get_audit_report called");
            let from = req
                .from_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(1)))
                .unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(1));
            let to = req
                .to_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(|| chrono::Utc::now());

            match self
                .handler
                .get_audit_report(req.tenant_id, from, to, req.event_types)
                .await
            {
                Ok(result) => Ok(Response::new(GetAuditReportResponse {
                    report_id: result.report_id,
                    total_events: result.total_events,
                    included_event_types: result.included_event_types,
                    generated_at: Some(to_prost_timestamp(result.generated_at)),
                    checksum: result.checksum,
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "get_audit_report failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn export_audit_report(
        &self,
        request: Request<ExportAuditReportRequest>,
    ) -> Result<Response<ExportAuditReportResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!("export_audit_report called");
            match self
                .handler
                .export_audit_report(req.report_id, req.tenant_id)
                .await
            {
                Ok(result) => Ok(Response::new(ExportAuditReportResponse {
                    report_id: result.report_id,
                    download_url: result.download_url,
                    checksum: result.checksum,
                    signature: result.signature,
                    expires_at: Some(to_prost_timestamp(result.expires_at)),
                    error: None,
                })),
                Err(e) => {
                    error!(error = %e, "export_audit_report failed");
                    Err(e.into())
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_signing_keys(
        &self,
        _request: Request<GetSigningKeysRequest>,
    ) -> Result<Response<GetSigningKeysResponse>, Status> {
        // Stub: signing key management would integrate with Vault or HSM
        Ok(Response::new(GetSigningKeysResponse {
            keys: vec![ussd_kernel_common::v1::common::SigningKeyInfo {
                key_id: "primary-audit-key-001".to_string(),
                algorithm: "ed25519".to_string(),
                created_at: Some(to_prost_timestamp(chrono::Utc::now())),
                expires_at: Some(to_prost_timestamp(chrono::Utc::now() + chrono::Duration::days(365))),
                is_active: true,
                public_key_pem: String::new(),
            }],
            error: None,
        }))
    }

    async fn health(
        &self,
        _request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse {
            status: ServingStatus::Serving as i32,
            version: env!("CARGO_PKG_VERSION").to_string(),
            timestamp: Some(prost_types::Timestamp::from(std::time::SystemTime::now())),
            dependencies: std::collections::HashMap::new(),
            metadata: Default::default(),
        }))
    }
}

fn to_prost_timestamp(dt: chrono::DateTime<chrono::Utc>) -> prost_types::Timestamp {
    let system_time: std::time::SystemTime = dt.into();
    prost_types::Timestamp::from(system_time)
}

fn json_to_prost_value(v: serde_json::Value) -> prost_types::Value {
    use prost_types::value::Kind;
    prost_types::Value {
        kind: Some(match v {
            serde_json::Value::Null => Kind::NullValue(0),
            serde_json::Value::Bool(b) => Kind::BoolValue(b),
            serde_json::Value::Number(n) => {
                Kind::NumberValue(n.as_f64().unwrap_or(0.0))
            }
            serde_json::Value::String(s) => Kind::StringValue(s),
            serde_json::Value::Array(arr) => {
                let list = prost_types::ListValue {
                    values: arr.into_iter().map(json_to_prost_value).collect(),
                };
                Kind::ListValue(list)
            }
            serde_json::Value::Object(map) => {
                let mut s = prost_types::Struct::default();
                s.fields
                    .extend(map.into_iter().map(|(k, v)| (k, json_to_prost_value(v))));
                Kind::StructValue(s)
            }
        }),
    }
}
