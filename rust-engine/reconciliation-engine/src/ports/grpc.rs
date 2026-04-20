use std::collections::HashMap;

use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use tonic::{Request, Response, Status};
use tracing::{error, info, info_span, Instrument};
use uuid::Uuid;

use ussd_kernel_common::v1::common::{
    BatchOperationResult, Error as ProtoError, ErrorCode, HealthRequest, HealthResponse,
    Money as ProtoMoney,
    PaginationMetadata,
};
use ussd_kernel_common::v1::common::health_response::ServingStatus;
use ussd_kernel_common::v1::reconciliation::reconciliation_service_server::ReconciliationService;
use ussd_kernel_common::v1::reconciliation::{
    BulkResolveDiscrepanciesRequest, DiscrepancyType as ProtoDiscrepancyType,
    GenerateReportRequest, GenerateReportResponse, GetMatchingRuleRequest,
    GetReconciliationItemsRequest, GetReconciliationItemsResponse,
    GetReconciliationRunRequest, ListMatchingRulesRequest, ListMatchingRulesResponse,
    ListReconciliationRunsRequest, ListReconciliationRunsResponse, MatchingRule as ProtoMatchingRule,
    ReconciliationItem as ProtoReconciliationItem, ReconciliationRun as ProtoReconciliationRun,
    ReconciliationStatus as ProtoReconciliationStatus, ResolutionAction as ProtoResolutionAction,
    ResolveDiscrepancyRequest, StartReconciliationRequest,
};

use crate::application::handler::ReconciliationHandler;
use crate::domain::discrepancy::{DiscrepancyType, ResolutionAction, ReconciliationStatus};
use crate::domain::error::ReconciliationError;


#[derive(Debug, Clone)]
pub struct ReconciliationGrpcServer {
    pub handler: ReconciliationHandler,
}

impl ReconciliationGrpcServer {
    fn map_domain_error(&self, e: ReconciliationError, trace_id: &str) -> (Status, Option<ProtoError>) {
        let (code, proto_code) = match &e {
            ReconciliationError::InvalidArgument(_) => {
                (Status::invalid_argument(e.to_string()), ErrorCode::InvalidArgument)
            }
            ReconciliationError::NotFound(_) => {
                (Status::not_found(e.to_string()), ErrorCode::NotFound)
            }
            ReconciliationError::AlreadyRunning => {
                (Status::already_exists(e.to_string()), ErrorCode::AlreadyExists)
            }
            ReconciliationError::ProviderError(_) => {
                (Status::failed_precondition(e.to_string()), ErrorCode::PaymentProviderError)
            }
            ReconciliationError::InvalidStatusTransition { from: _, to: _ } => {
                (Status::failed_precondition(e.to_string()), ErrorCode::FailedPrecondition)
            }
            _ => (Status::internal(e.to_string()), ErrorCode::Internal),
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

fn parse_uuid(s: &str) -> Result<Uuid, Status> {
    Uuid::parse_str(s).map_err(|_| Status::invalid_argument(format!("Invalid UUID: {}", s)))
}

fn extract_trace_id<T>(req: &Request<T>) -> String {
    req.metadata()
        .get("x-trace-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string()
}

fn chrono_to_prost(dt: chrono::DateTime<chrono::Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: dt.timestamp(),
        nanos: dt.timestamp_subsec_nanos() as i32,
    }
}

fn map_proto_money(amount: Decimal, currency: &str) -> Option<ProtoMoney> {
    Some(ProtoMoney {
        currency_code: currency.to_string(),
        amount_cents: (amount * Decimal::new(100, 0)).to_i64().unwrap_or(0),
        currency: 0,
    })
}

fn map_domain_status(status: ReconciliationStatus) -> i32 {
    match status {
        ReconciliationStatus::Pending => ProtoReconciliationStatus::ReconciliationPending as i32,
        ReconciliationStatus::Running => ProtoReconciliationStatus::ReconciliationRunning as i32,
        ReconciliationStatus::Completed => ProtoReconciliationStatus::ReconciliationCompleted as i32,
        ReconciliationStatus::Failed => ProtoReconciliationStatus::ReconciliationFailed as i32,
        ReconciliationStatus::PartiallyResolved => {
            ProtoReconciliationStatus::ReconciliationPartiallyResolved as i32
        }
        ReconciliationStatus::Approved => ProtoReconciliationStatus::ReconciliationApproved as i32,
    }
}

fn map_proto_status(status: i32) -> Result<ReconciliationStatus, Status> {
    match ProtoReconciliationStatus::try_from(status) {
        Ok(ProtoReconciliationStatus::ReconciliationPending) => Ok(ReconciliationStatus::Pending),
        Ok(ProtoReconciliationStatus::ReconciliationRunning) => Ok(ReconciliationStatus::Running),
        Ok(ProtoReconciliationStatus::ReconciliationCompleted) => Ok(ReconciliationStatus::Completed),
        Ok(ProtoReconciliationStatus::ReconciliationFailed) => Ok(ReconciliationStatus::Failed),
        Ok(ProtoReconciliationStatus::ReconciliationPartiallyResolved) => {
            Ok(ReconciliationStatus::PartiallyResolved)
        }
        Ok(ProtoReconciliationStatus::ReconciliationApproved) => Ok(ReconciliationStatus::Approved),
        _ => Err(Status::invalid_argument(format!("Invalid status: {}", status))),
    }
}

fn map_domain_discrepancy_type(dt: DiscrepancyType) -> i32 {
    match dt {
        DiscrepancyType::MissingInternal => ProtoDiscrepancyType::MissingInternal as i32,
        DiscrepancyType::MissingExternal => ProtoDiscrepancyType::MissingExternal as i32,
        DiscrepancyType::AmountMismatch => ProtoDiscrepancyType::AmountMismatch as i32,
        DiscrepancyType::StatusMismatch => ProtoDiscrepancyType::StatusMismatch as i32,
        DiscrepancyType::DuplicateInternal => ProtoDiscrepancyType::DuplicateInternal as i32,
        DiscrepancyType::DuplicateExternal => ProtoDiscrepancyType::DuplicateExternal as i32,
        DiscrepancyType::FeeMismatch => ProtoDiscrepancyType::FeeMismatch as i32,
        DiscrepancyType::TimestampMismatch => ProtoDiscrepancyType::TimestampMismatch as i32,
        DiscrepancyType::CurrencyMismatch => ProtoDiscrepancyType::CurrencyMismatch as i32,
    }
}

fn map_proto_discrepancy_type(dt: i32) -> Result<DiscrepancyType, Status> {
    match ProtoDiscrepancyType::try_from(dt) {
        Ok(ProtoDiscrepancyType::MissingInternal) => Ok(DiscrepancyType::MissingInternal),
        Ok(ProtoDiscrepancyType::MissingExternal) => Ok(DiscrepancyType::MissingExternal),
        Ok(ProtoDiscrepancyType::AmountMismatch) => Ok(DiscrepancyType::AmountMismatch),
        Ok(ProtoDiscrepancyType::StatusMismatch) => Ok(DiscrepancyType::StatusMismatch),
        Ok(ProtoDiscrepancyType::DuplicateInternal) => Ok(DiscrepancyType::DuplicateInternal),
        Ok(ProtoDiscrepancyType::DuplicateExternal) => Ok(DiscrepancyType::DuplicateExternal),
        Ok(ProtoDiscrepancyType::FeeMismatch) => Ok(DiscrepancyType::FeeMismatch),
        Ok(ProtoDiscrepancyType::TimestampMismatch) => Ok(DiscrepancyType::TimestampMismatch),
        Ok(ProtoDiscrepancyType::CurrencyMismatch) => Ok(DiscrepancyType::CurrencyMismatch),
        _ => Err(Status::invalid_argument(format!("Invalid discrepancy type: {}", dt))),
    }
}

fn map_domain_resolution_action(ra: ResolutionAction) -> i32 {
    match ra {
        ResolutionAction::CorrectInternal => ProtoResolutionAction::ResolutionCorrectInternal as i32,
        ResolutionAction::CorrectExternal => ProtoResolutionAction::ResolutionCorrectExternal as i32,
        ResolutionAction::CreateAdjustment => ProtoResolutionAction::ResolutionCreateAdjustment as i32,
        ResolutionAction::Ignore => ProtoResolutionAction::ResolutionIgnore as i32,
        ResolutionAction::Escalate => ProtoResolutionAction::ResolutionEscalate as i32,
        ResolutionAction::Approve => ProtoResolutionAction::ResolutionApprove as i32,
    }
}

fn map_proto_resolution_action(ra: i32) -> Result<ResolutionAction, Status> {
    match ProtoResolutionAction::try_from(ra) {
        Ok(ProtoResolutionAction::ResolutionCorrectInternal) => Ok(ResolutionAction::CorrectInternal),
        Ok(ProtoResolutionAction::ResolutionCorrectExternal) => Ok(ResolutionAction::CorrectExternal),
        Ok(ProtoResolutionAction::ResolutionCreateAdjustment) => Ok(ResolutionAction::CreateAdjustment),
        Ok(ProtoResolutionAction::ResolutionIgnore) => Ok(ResolutionAction::Ignore),
        Ok(ProtoResolutionAction::ResolutionEscalate) => Ok(ResolutionAction::Escalate),
        Ok(ProtoResolutionAction::ResolutionApprove) => Ok(ResolutionAction::Approve),
        _ => Err(Status::invalid_argument(format!("Invalid resolution action: {}", ra))),
    }
}

fn map_run_to_proto(run: crate::domain::reconciliation_run::ReconciliationRun) -> ProtoReconciliationRun {
    ProtoReconciliationRun {
        run_id: run.run_id.to_string(),
        tenant_id: run.tenant_id.to_string(),
        provider_name: run.provider_name,
        status: map_domain_status(run.status),
        period_start: Some(chrono_to_prost(run.period_start)),
        period_end: Some(chrono_to_prost(run.period_end)),
        started_at: run.started_at.map(chrono_to_prost),
        completed_at: run.completed_at.map(chrono_to_prost),
        total_records: run.total_records,
        matched_count: run.matched_count,
        discrepancy_count: run.discrepancy_count,
        resolved_count: run.resolved_count,
        initiated_by: run.initiated_by,
        approved_by: run.approved_by.unwrap_or_default(),
        approved_at: run.approved_at.map(chrono_to_prost),
        internal_total_amount: map_proto_money(run.internal_total, "USD"),
        external_total_amount: map_proto_money(run.external_total, "USD"),
        discrepancy_amount: map_proto_money(run.discrepancy_amount, "USD"),
        error: None,
    }
}

fn map_item_to_proto(item: crate::domain::reconciliation_item::ReconciliationItem) -> ProtoReconciliationItem {
    ProtoReconciliationItem {
        item_id: item.item_id.to_string(),
        run_id: item.run_id.to_string(),
        transaction_id: item.transaction_id,
        discrepancy_type: map_domain_discrepancy_type(item.discrepancy_type),
        internal_status: item.internal_status,
        external_status: item.external_status,
        internal_amount: map_proto_money(item.internal_amount, "USD"),
        external_amount: map_proto_money(item.external_amount, "USD"),
        difference: map_proto_money(item.difference, "USD"),
        resolved: item.resolved,
        resolution_action: item.resolution_action.map(map_domain_resolution_action).unwrap_or(0),
        resolved_by: item.resolved_by.unwrap_or_default(),
        resolved_at: item.resolved_at.map(chrono_to_prost),
        notes: item.notes.unwrap_or_default(),
        error: None,
    }
}

fn map_rule_to_proto(rule: crate::domain::matching_rule::MatchingRule) -> ProtoMatchingRule {
    ProtoMatchingRule {
        rule_id: rule.rule_id.to_string(),
        tenant_id: rule.tenant_id.to_string(),
        provider_name: rule.provider_name,
        rule_name: rule.rule_name,
        match_fields: rule.match_fields,
        tolerance_amount: map_proto_money(rule.tolerance_amount, "USD"),
        tolerance_time_seconds: rule.tolerance_time_seconds,
        auto_resolve: rule.auto_resolve,
        is_active: rule.is_active,
        created_at: rule.created_at.map(chrono_to_prost),
        updated_at: rule.updated_at.map(chrono_to_prost),
        error: None,
    }
}

#[tonic::async_trait]
impl ReconciliationService for ReconciliationGrpcServer {
    async fn start_reconciliation(
        &self,
        request: Request<StartReconciliationRequest>,
    ) -> Result<Response<ProtoReconciliationRun>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("start_reconciliation"));

        async {
            info!(trace_id = %trace_id, "Processing start_reconciliation request");
            let req = request.into_inner();

            let tenant_id = parse_uuid(&req.tenant_id)?;
            let period_start = req
                .period_start
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(chrono::Utc::now);
            let period_end = req
                .period_end
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(chrono::Utc::now);
            let tolerance = req
                .tolerance_amount
                .as_ref()
                .map(|m| Decimal::new(m.amount_cents, 2))
                .unwrap_or_else(|| Decimal::new(1, 2));

            match self
                .handler
                .start_reconciliation(
                    tenant_id,
                    &req.provider_name,
                    period_start,
                    period_end,
                    &req.initiated_by,
                    tolerance,
                )
                .await
            {
                Ok(run) => Ok(Response::new(map_run_to_proto(run))),
                Err(e) => {
                    error!(error = %e, trace_id = %trace_id, "start_reconciliation failed");
                    let (status, proto_err) = self.map_domain_error(e, &trace_id);
                    let mut resp = ProtoReconciliationRun::default();
                    resp.error = proto_err;
                    Err(status)
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_reconciliation_run(
        &self,
        request: Request<GetReconciliationRunRequest>,
    ) -> Result<Response<ProtoReconciliationRun>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_reconciliation_run"));

        async {
            let req = request.into_inner();
            let run_id = parse_uuid(&req.run_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_reconciliation_run(run_id, tenant_id).await {
                Ok(run) => Ok(Response::new(map_run_to_proto(run))),
                Err(e) => {
                    let (status, proto_err) = self.map_domain_error(e, &trace_id);
                    let mut resp = ProtoReconciliationRun::default();
                    resp.error = proto_err;
                    Err(status)
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_reconciliation_runs(
        &self,
        request: Request<ListReconciliationRunsRequest>,
    ) -> Result<Response<ListReconciliationRunsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_reconciliation_runs"));

        async {
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let provider_name = if req.provider_name.is_empty() {
                None
            } else {
                Some(req.provider_name.as_str())
            };
            let statuses: Result<Vec<_>, _> = req.statuses.into_iter().map(map_proto_status).collect();
            let statuses = statuses?;
            let from = req
                .from_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(|| chrono::Utc::now() - chrono::Duration::days(30));
            let to = req
                .to_date
                .map(|t| chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32).unwrap_or_else(|| chrono::Utc::now()))
                .unwrap_or_else(chrono::Utc::now);

            match self
                .handler
                .list_reconciliation_runs(tenant_id, provider_name, statuses, from, to)
                .await
            {
                Ok(runs) => {
                    let total_count = runs.len() as i32;
                    Ok(Response::new(ListReconciliationRunsResponse {
                        runs: runs.into_iter().map(map_run_to_proto).collect(),
                        pagination: Some(PaginationMetadata {
                            total_count,
                            next_page_token: String::new(),
                            previous_page_token: String::new(),
                            has_more: false,
                        }),
                        total_count,
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(ListReconciliationRunsResponse {
                        runs: vec![],
                        pagination: None,
                        total_count: 0,
                        error: proto_err,
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_reconciliation_items(
        &self,
        request: Request<GetReconciliationItemsRequest>,
    ) -> Result<Response<GetReconciliationItemsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_reconciliation_items"));

        async {
            let req = request.into_inner();
            let run_id = parse_uuid(&req.run_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let discrepancy_types: Result<Vec<_>, _> = req
                .discrepancy_types
                .into_iter()
                .map(map_proto_discrepancy_type)
                .collect();
            let discrepancy_types = discrepancy_types?;

            match self
                .handler
                .get_reconciliation_items(run_id, tenant_id, discrepancy_types, req.unresolved_only)
                .await
            {
                Ok(items) => {
                    let total_count = items.len() as i32;
                    Ok(Response::new(GetReconciliationItemsResponse {
                        items: items.into_iter().map(map_item_to_proto).collect(),
                        pagination: Some(PaginationMetadata {
                            total_count,
                            next_page_token: String::new(),
                            previous_page_token: String::new(),
                            has_more: false,
                        }),
                        total_count,
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(GetReconciliationItemsResponse {
                        items: vec![],
                        pagination: None,
                        total_count: 0,
                        error: proto_err,
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn resolve_discrepancy(
        &self,
        request: Request<ResolveDiscrepancyRequest>,
    ) -> Result<Response<ProtoReconciliationItem>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("resolve_discrepancy"));

        async {
            let req = request.into_inner();
            let item_id = parse_uuid(&req.item_id)?;
            let run_id = parse_uuid(&req.run_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let action = map_proto_resolution_action(req.action)?;

            match self
                .handler
                .resolve_discrepancy(item_id, run_id, tenant_id, action, &req.notes, &req.resolved_by)
                .await
            {
                Ok(item) => Ok(Response::new(map_item_to_proto(item))),
                Err(e) => {
                    let (status, proto_err) = self.map_domain_error(e, &trace_id);
                    let mut resp = ProtoReconciliationItem::default();
                    resp.error = proto_err;
                    Err(status)
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn bulk_resolve_discrepancies(
        &self,
        request: Request<BulkResolveDiscrepanciesRequest>,
    ) -> Result<Response<BatchOperationResult>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("bulk_resolve_discrepancies"));

        async {
            let req = request.into_inner();
            let run_id = parse_uuid(&req.run_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let item_ids: Result<Vec<_>, _> = req.item_ids.iter().map(|s| parse_uuid(s)).collect();
            let item_ids = item_ids?;
            let action = map_proto_resolution_action(req.action)?;

            match self
                .handler
                .bulk_resolve_discrepancies(run_id, tenant_id, item_ids.clone(), action, &req.notes, &req.resolved_by)
                .await
            {
                Ok(success_count) => Ok(Response::new(BatchOperationResult {
                    batch_id: Uuid::new_v4().to_string(),
                    total_count: item_ids.len() as i32,
                    success_count,
                    failure_count: (item_ids.len() as i32) - success_count,
                    errors: vec![],
                })),
                Err(e) => {
                    let (_, _proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(BatchOperationResult {
                        batch_id: Uuid::new_v4().to_string(),
                        total_count: item_ids.len() as i32,
                        success_count: 0,
                        failure_count: item_ids.len() as i32,
                        errors: vec![],
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn generate_report(
        &self,
        request: Request<GenerateReportRequest>,
    ) -> Result<Response<GenerateReportResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("generate_report"));

        async {
            let req = request.into_inner();
            let run_id = parse_uuid(&req.run_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.generate_report(run_id, tenant_id, &req.format).await {
                Ok((report_id, download_url)) => Ok(Response::new(GenerateReportResponse {
                    report_id: report_id.to_string(),
                    download_url,
                    generated_at: Some(chrono_to_prost(chrono::Utc::now())),
                    error: None,
                })),
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(GenerateReportResponse {
                        report_id: String::new(),
                        download_url: String::new(),
                        generated_at: None,
                        error: proto_err,
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_matching_rule(
        &self,
        request: Request<GetMatchingRuleRequest>,
    ) -> Result<Response<ProtoMatchingRule>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_matching_rule"));

        async {
            let req = request.into_inner();
            let rule_id = parse_uuid(&req.rule_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_matching_rule(rule_id, tenant_id).await {
                Ok(rule) => Ok(Response::new(map_rule_to_proto(rule))),
                Err(e) => {
                    let (status, proto_err) = self.map_domain_error(e, &trace_id);
                    let mut resp = ProtoMatchingRule::default();
                    resp.error = proto_err;
                    Err(status)
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_matching_rules(
        &self,
        request: Request<ListMatchingRulesRequest>,
    ) -> Result<Response<ListMatchingRulesResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_matching_rules"));

        async {
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let provider_name = if req.provider_name.is_empty() {
                None
            } else {
                Some(req.provider_name.as_str())
            };

            match self.handler.list_matching_rules(tenant_id, provider_name).await {
                Ok(rules) => {
                    let total_count = rules.len() as i32;
                    Ok(Response::new(ListMatchingRulesResponse {
                        rules: rules.into_iter().map(map_rule_to_proto).collect(),
                        pagination: Some(PaginationMetadata {
                            total_count,
                            next_page_token: String::new(),
                            previous_page_token: String::new(),
                            has_more: false,
                        }),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_, proto_err) = self.map_domain_error(e, &trace_id);
                    Ok(Response::new(ListMatchingRulesResponse {
                        rules: vec![],
                        pagination: None,
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
}
