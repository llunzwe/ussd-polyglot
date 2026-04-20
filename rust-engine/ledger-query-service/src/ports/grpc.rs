// NOTE: Financial ledger queries (account balances, statements, settlements,
// suspense items, virtual accounts, liquidity positions, chart of accounts) are
// OUT OF SCOPE for the Open AI-USSD Kernel Engine. This service binds to
// localhost by default and is not reachable from the tenant network.
// Tenant applications should query their own provider-side financial systems.

use chrono::{DateTime, Utc};
use rust_decimal::prelude::ToPrimitive;
use std::collections::HashMap;
use tonic::{Request, Response, Status};
use tracing::{info, info_span, Instrument};
use uuid::Uuid;

use ussd_kernel_common::v1::common::{
    Error as ProtoError, ErrorCode, HealthRequest, HealthResponse, Money as ProtoMoney,
    Pagination as ProtoPagination, PaginationMetadata as ProtoPaginationMetadata,
};
use ussd_kernel_common::v1::common::health_response::ServingStatus;
use ussd_kernel_common::v1::ledger::ledger_query_service_server::LedgerQueryService;
use ussd_kernel_common::v1::ledger::virtual_account_service_server::VirtualAccountService;
use ussd_kernel_common::v1::ledger::liquidity_position_service_server::LiquidityPositionService;
use ussd_kernel_common::v1::ledger::settlement_service_server::SettlementService;
use ussd_kernel_common::v1::ledger::suspense_service_server::SuspenseService;
use ussd_kernel_common::v1::ledger::chart_of_accounts_service_server::ChartOfAccountsService;
use ussd_kernel_common::v1::ledger::*;

use crate::application::handler::LedgerQueryHandler;
use crate::domain::account::AccountType;
use crate::domain::error::LedgerQueryError;
use crate::domain::liquidity::{LiquidityPositionStatus, LiquidityPositionType};
use crate::domain::pagination::{Pagination, PaginationMetadata};
use crate::domain::settlement::{SettlementStatus, SettlementType};
use crate::domain::suspense::{SuspenseCategory, SuspenseResolutionType, SuspenseStatus};
use crate::domain::transaction::TransactionType;
use crate::domain::virtual_account::{VirtualAccountStatus, VirtualAccountType};

#[derive(Clone)]
pub struct LedgerQueryGrpcServer {
    pub handler: LedgerQueryHandler,
}

impl LedgerQueryGrpcServer {
    fn map_error(&self, e: LedgerQueryError, trace_id: &str) -> (Status, Option<ProtoError>) {
        let (status, code) = match &e {
            LedgerQueryError::AccountNotFound(_)
            | LedgerQueryError::TransactionNotFound(_)
            | LedgerQueryError::VirtualAccountNotFound(_)
            | LedgerQueryError::LiquidityPositionNotFound(_)
            | LedgerQueryError::SettlementNotFound(_)
            | LedgerQueryError::SuspenseItemNotFound(_)
            | LedgerQueryError::CoaEntryNotFound(_)
            | LedgerQueryError::PeriodEndBalanceNotFound(_) => {
                (Status::not_found(e.to_string()), ErrorCode::NotFound)
            }
            LedgerQueryError::InvalidDateRange(_) | LedgerQueryError::InvalidArgument(_) => {
                (Status::invalid_argument(e.to_string()), ErrorCode::InvalidArgument)
            }
            LedgerQueryError::DatabaseError(_) => {
                (Status::internal(e.to_string()), ErrorCode::Internal)
            }
            LedgerQueryError::Internal(_) => {
                (Status::internal(e.to_string()), ErrorCode::Internal)
            }
        };

        let proto_error = ProtoError {
            code: code as i32,
            message: e.to_string(),
            details: {
                let mut m = HashMap::new();
                m.insert("trace_id".to_string(), trace_id.to_string());
                m
            },
            trace_id: trace_id.to_string(),
            grpc_code: status.code() as i32,
        };

        (status, Some(proto_error))
    }
}

fn extract_trace_id<T>(req: &Request<T>) -> String {
    req.metadata()
        .get("x-trace-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string()
}

fn parse_uuid(s: &str) -> Result<Uuid, Status> {
    Uuid::parse_str(s).map_err(|_| Status::invalid_argument(format!("Invalid UUID: {}", s)))
}

fn chrono_to_prost(dt: DateTime<Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: dt.timestamp(),
        nanos: dt.timestamp_subsec_nanos() as i32,
    }
}

fn prost_to_chrono(ts: Option<prost_types::Timestamp>) -> Option<DateTime<Utc>> {
    ts.and_then(|t| {
        chrono::DateTime::from_timestamp(t.seconds, t.nanos as u32)
    })
}

fn decimal_to_money(amount: &rust_decimal::Decimal, currency: &str) -> Option<ProtoMoney> {
    Some(ProtoMoney {
        currency_code: currency.to_string(),
        amount_cents: (amount * rust_decimal::Decimal::new(100, 0))
            .round_dp(0)
            .to_i64()
            .unwrap_or(0),
        currency: 0,
    })
}

#[allow(dead_code)]
fn money_to_decimal(money: Option<&ProtoMoney>) -> Result<rust_decimal::Decimal, Status> {
    money
        .map(|m| rust_decimal::Decimal::new(m.amount_cents, 2))
        .ok_or_else(|| Status::invalid_argument("Money amount is required"))
}

fn map_proto_pagination(p: Option<ProtoPagination>) -> Pagination {
    match p {
        Some(pp) => Pagination {
            page_size: pp.page_size.max(1).min(1000),
            page_token: pp.page_token,
        },
        None => Pagination {
            page_size: 50,
            page_token: String::new(),
        },
    }
}

fn map_domain_pagination(meta: &PaginationMetadata) -> ProtoPaginationMetadata {
    ProtoPaginationMetadata {
        total_count: meta.total_count,
        next_page_token: meta.next_page_token.clone(),
        previous_page_token: meta.previous_page_token.clone(),
        has_more: meta.has_more,
    }
}

fn map_domain_account_type(t: AccountType) -> i32 {
    t.as_i32()
}

fn map_proto_transaction_type(t: i32) -> Option<TransactionType> {
    TransactionType::from_i32(t)
}

fn map_domain_transaction_type(t: TransactionType) -> i32 {
    t.as_i32()
}

fn map_proto_virtual_account_type(t: i32) -> Option<VirtualAccountType> {
    VirtualAccountType::from_i32(t)
}

fn map_domain_virtual_account_type(t: VirtualAccountType) -> i32 {
    t.as_i32()
}

fn map_proto_virtual_account_status(t: i32) -> Option<VirtualAccountStatus> {
    VirtualAccountStatus::from_i32(t)
}

fn map_domain_virtual_account_status(t: VirtualAccountStatus) -> i32 {
    t.as_i32()
}

fn map_proto_liquidity_position_type(t: i32) -> Option<LiquidityPositionType> {
    LiquidityPositionType::from_i32(t)
}

fn map_domain_liquidity_position_type(t: LiquidityPositionType) -> i32 {
    t.as_i32()
}

fn map_proto_liquidity_position_status(t: i32) -> Option<LiquidityPositionStatus> {
    LiquidityPositionStatus::from_i32(t)
}

fn map_domain_liquidity_position_status(t: LiquidityPositionStatus) -> i32 {
    t.as_i32()
}

fn map_proto_settlement_type(t: i32) -> Option<SettlementType> {
    SettlementType::from_i32(t)
}

fn map_domain_settlement_type(t: SettlementType) -> i32 {
    t.as_i32()
}

fn map_proto_settlement_status(t: i32) -> Option<SettlementStatus> {
    SettlementStatus::from_i32(t)
}

fn map_domain_settlement_status(t: SettlementStatus) -> i32 {
    t.as_i32()
}

fn map_proto_suspense_category(t: i32) -> Option<SuspenseCategory> {
    SuspenseCategory::from_i32(t)
}

fn map_domain_suspense_category(t: SuspenseCategory) -> i32 {
    t.as_i32()
}

fn map_proto_suspense_status(t: i32) -> Option<SuspenseStatus> {
    SuspenseStatus::from_i32(t)
}

fn map_domain_suspense_status(t: SuspenseStatus) -> i32 {
    t.as_i32()
}

#[allow(dead_code)]
fn map_proto_suspense_resolution_type(t: i32) -> Option<SuspenseResolutionType> {
    SuspenseResolutionType::from_i32(t)
}

fn map_domain_suspense_resolution_type(t: SuspenseResolutionType) -> i32 {
    t.as_i32()
}

fn prost_struct_to_json_value(s: prost_types::Struct) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    for (k, v) in s.fields {
        map.insert(k, prost_value_to_json_value(v));
    }
    serde_json::Value::Object(map)
}

fn prost_value_to_json_value(v: prost_types::Value) -> serde_json::Value {
    match v.kind {
        Some(prost_types::value::Kind::NullValue(_)) => serde_json::Value::Null,
        Some(prost_types::value::Kind::NumberValue(n)) => serde_json::Value::from(n),
        Some(prost_types::value::Kind::StringValue(s)) => serde_json::Value::String(s),
        Some(prost_types::value::Kind::BoolValue(b)) => serde_json::Value::Bool(b),
        Some(prost_types::value::Kind::StructValue(s)) => prost_struct_to_json_value(s),
        Some(prost_types::value::Kind::ListValue(l)) => {
            serde_json::Value::Array(l.values.into_iter().map(prost_value_to_json_value).collect())
        }
        None => serde_json::Value::Null,
    }
}

fn map_domain_transaction(t: crate::domain::transaction::Transaction) -> Transaction {
    Transaction {
        transaction_id: t.transaction_id.to_string(),
        transaction_uuid: t.transaction_uuid,
        tenant_id: t.tenant_id.to_string(),
        account_id: t.account_id.to_string(),
        transaction_type: map_domain_transaction_type(t.transaction_type),
        amount: decimal_to_money(&t.amount, "USD"),
        balance_after: decimal_to_money(&t.balance_after, "USD"),
        description: t.description,
        reference: t.reference,
        posted_at: Some(chrono_to_prost(t.posted_at)),
        effective_at: Some(chrono_to_prost(t.effective_at)),
        session_id: t.session_id,
        payment_id: t.payment_id,
        metadata: t.metadata,
        version: t.version,
        correlation_id: t.correlation_id,
        idempotency_key: t.idempotency_key,
        status: t.status,
        record_hash: t.record_hash,
        previous_hash: t.previous_hash,
        error: None,
    }
}

#[tonic::async_trait]
impl LedgerQueryService for LedgerQueryGrpcServer {
    async fn get_account_balance(
        &self,
        request: Request<GetAccountBalanceRequest>,
    ) -> Result<Response<AccountBalance>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_account_balance"));

        async {
            info!(trace_id = %trace_id, "Processing get_account_balance request");
            let req = request.into_inner();
            let account_id = parse_uuid(&req.account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let as_of = prost_to_chrono(req.as_of);

            match self.handler.get_account_balance(account_id, tenant_id, as_of).await {
                Ok(balance) => Ok(Response::new(AccountBalance {
                    account_id: balance.account_id.to_string(),
                    tenant_id: balance.tenant_id.to_string(),
                    account_type: map_domain_account_type(balance.account_type),
                    current_balance: decimal_to_money(&balance.current_balance, &balance.currency_code),
                    available_balance: decimal_to_money(&balance.available_balance, &balance.currency_code),
                    hold_balance: decimal_to_money(&balance.hold_balance, &balance.currency_code),
                    currency_code: balance.currency_code,
                    as_of: Some(chrono_to_prost(balance.as_of)),
                    version: balance.version,
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(AccountBalance {
                        account_id: req.account_id,
                        tenant_id: req.tenant_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_account_statement(
        &self,
        request: Request<GetAccountStatementRequest>,
    ) -> Result<Response<GetAccountStatementResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_account_statement"));

        async {
            info!(trace_id = %trace_id, "Processing get_account_statement request");
            let req = request.into_inner();
            let account_id = parse_uuid(&req.account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let from = prost_to_chrono(req.from_date)
                .ok_or_else(|| Status::invalid_argument("from_date is required"))?;
            let to = prost_to_chrono(req.to_date)
                .ok_or_else(|| Status::invalid_argument("to_date is required"))?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.get_account_statement(account_id, tenant_id, from, to, pagination).await {
                Ok((transactions, meta, opening, closing, credits, debits, fees)) => {
                    let txns = transactions.into_iter().map(map_domain_transaction).collect();
                    Ok(Response::new(GetAccountStatementResponse {
                        account_id: req.account_id,
                        transactions: txns,
                        pagination: Some(map_domain_pagination(&meta)),
                        opening_balance: decimal_to_money(&opening, "USD"),
                        closing_balance: decimal_to_money(&closing, "USD"),
                        total_credits: decimal_to_money(&credits, "USD"),
                        total_debits: decimal_to_money(&debits, "USD"),
                        total_fees: decimal_to_money(&fees, "USD"),
                        total_count: meta.total_count,
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetAccountStatementResponse {
                        account_id: req.account_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_transaction_by_id(
        &self,
        request: Request<GetTransactionByIdRequest>,
    ) -> Result<Response<Transaction>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_transaction_by_id"));

        async {
            info!(trace_id = %trace_id, "Processing get_transaction_by_id request");
            let req = request.into_inner();
            let transaction_id = parse_uuid(&req.transaction_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_transaction_by_id(transaction_id, tenant_id).await {
                Ok(txn) => Ok(Response::new(map_domain_transaction(txn))),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(Transaction {
                        transaction_id: req.transaction_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_transactions(
        &self,
        request: Request<ListTransactionsRequest>,
    ) -> Result<Response<ListTransactionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_transactions"));

        async {
            info!(trace_id = %trace_id, "Processing list_transactions request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let account_ids: Result<Vec<Uuid>, Status> = req.account_ids.iter().map(|s| parse_uuid(s)).collect();
            let account_ids = account_ids?;
            let types: Vec<TransactionType> = req.types.iter().filter_map(|&t| map_proto_transaction_type(t)).collect();
            let from = prost_to_chrono(req.from_date)
                .ok_or_else(|| Status::invalid_argument("from_date is required"))?;
            let to = prost_to_chrono(req.to_date)
                .ok_or_else(|| Status::invalid_argument("to_date is required"))?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_transactions(tenant_id, account_ids, types, from, to, pagination).await {
                Ok((transactions, meta, total_count, credits, debits, fees)) => {
                    let txns = transactions.into_iter().map(map_domain_transaction).collect();
                    Ok(Response::new(ListTransactionsResponse {
                        transactions: txns,
                        pagination: Some(map_domain_pagination(&meta)),
                        total_count,
                        total_credits: decimal_to_money(&credits, "USD"),
                        total_debits: decimal_to_money(&debits, "USD"),
                        total_fees: decimal_to_money(&fees, "USD"),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListTransactionsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn search_transactions(
        &self,
        request: Request<SearchTransactionsRequest>,
    ) -> Result<Response<ListTransactionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("search_transactions"));

        async {
            info!(trace_id = %trace_id, "Processing search_transactions request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let query = req.query;
            let filters = req.filters.map(prost_struct_to_json_value);
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.search_transactions(tenant_id, &query, filters, pagination).await {
                Ok((transactions, meta, total_count, credits, debits, fees)) => {
                    let txns = transactions.into_iter().map(map_domain_transaction).collect();
                    Ok(Response::new(ListTransactionsResponse {
                        transactions: txns,
                        pagination: Some(map_domain_pagination(&meta)),
                        total_count,
                        total_credits: decimal_to_money(&credits, "USD"),
                        total_debits: decimal_to_money(&debits, "USD"),
                        total_fees: decimal_to_money(&fees, "USD"),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListTransactionsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_account_summary(
        &self,
        request: Request<GetAccountSummaryRequest>,
    ) -> Result<Response<AccountSummary>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_account_summary"));

        async {
            info!(trace_id = %trace_id, "Processing get_account_summary request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let as_of = prost_to_chrono(req.as_of);

            match self.handler.get_account_summary(tenant_id, as_of).await {
                Ok(summary) => Ok(Response::new(AccountSummary {
                    tenant_id: summary.tenant_id.to_string(),
                    total_accounts: summary.total_accounts,
                    balances: summary.balances.into_iter().map(|b| BalanceByType {
                        account_type: map_domain_account_type(b.account_type),
                        balance: decimal_to_money(&b.balance, "USD"),
                        account_count: b.account_count,
                    }).collect(),
                    total_liabilities: decimal_to_money(&summary.total_liabilities, "USD"),
                    total_assets: decimal_to_money(&summary.total_assets, "USD"),
                    as_of: Some(chrono_to_prost(summary.as_of)),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(AccountSummary {
                        tenant_id: req.tenant_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn rebuild_account_view(
        &self,
        request: Request<RebuildAccountViewRequest>,
    ) -> Result<Response<RebuildAccountViewResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("rebuild_account_view"));

        async {
            info!(trace_id = %trace_id, "Processing rebuild_account_view request");
            let req = request.into_inner();
            let account_id = parse_uuid(&req.account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.rebuild_account_view(account_id, tenant_id, req.dry_run).await {
                Ok((success, events_replayed, reconciled_balance)) => Ok(Response::new(RebuildAccountViewResponse {
                    account_id: req.account_id,
                    success,
                    events_replayed,
                    completed_at: Some(prost_types::Timestamp::from(std::time::SystemTime::now())),
                    reconciled_balance: decimal_to_money(&reconciled_balance, "USD"),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(RebuildAccountViewResponse {
                        account_id: req.account_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_movement_legs(
        &self,
        request: Request<GetMovementLegsRequest>,
    ) -> Result<Response<GetMovementLegsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_movement_legs"));

        async {
            info!(trace_id = %trace_id, "Processing get_movement_legs request");
            let req = request.into_inner();
            let transaction_id = parse_uuid(&req.transaction_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_movement_legs(transaction_id, tenant_id).await {
                Ok(legs) => Ok(Response::new(GetMovementLegsResponse {
                    transaction_id: req.transaction_id,
                    legs: legs.into_iter().map(|l| MovementLeg {
                        leg_id: l.leg_id,
                        leg_sequence: l.leg_sequence,
                        account_id: l.account_id,
                        direction: l.direction,
                        amount: decimal_to_money(&l.amount, &l.currency),
                        currency: l.currency,
                        coa_code: l.coa_code,
                        description: l.description,
                        posted_at: Some(chrono_to_prost(l.posted_at)),
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetMovementLegsResponse {
                        transaction_id: req.transaction_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn verify_double_entry(
        &self,
        request: Request<VerifyDoubleEntryRequest>,
    ) -> Result<Response<VerifyDoubleEntryResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("verify_double_entry"));

        async {
            info!(trace_id = %trace_id, "Processing verify_double_entry request");
            let req = request.into_inner();
            let transaction_id = parse_uuid(&req.transaction_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.verify_double_entry(transaction_id, tenant_id).await {
                Ok((is_balanced, total_debits, total_credits, difference)) => Ok(Response::new(VerifyDoubleEntryResponse {
                    transaction_id: req.transaction_id,
                    is_balanced,
                    total_debits: decimal_to_money(&total_debits, "USD"),
                    total_credits: decimal_to_money(&total_credits, "USD"),
                    difference: decimal_to_money(&difference, "USD"),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(VerifyDoubleEntryResponse {
                        transaction_id: req.transaction_id,
                        error: proto_err,
                        ..Default::default()
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

#[tonic::async_trait]
impl VirtualAccountService for LedgerQueryGrpcServer {
    async fn get_virtual_account(
        &self,
        request: Request<GetVirtualAccountRequest>,
    ) -> Result<Response<VirtualAccount>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_virtual_account"));

        async {
            info!(trace_id = %trace_id, "Processing get_virtual_account request");
            let req = request.into_inner();
            let virtual_account_id = parse_uuid(&req.virtual_account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_virtual_account(virtual_account_id, tenant_id).await {
                Ok(va) => Ok(Response::new(VirtualAccount {
                    virtual_account_id: va.virtual_account_id.to_string(),
                    parent_account_id: va.parent_account_id.to_string(),
                    virtual_account_name: va.virtual_account_name,
                    virtual_account_number: va.virtual_account_number,
                    virtual_account_type: map_domain_virtual_account_type(va.virtual_account_type),
                    status: map_domain_virtual_account_status(va.status),
                    current_balance: decimal_to_money(&va.current_balance, &va.currency),
                    available_balance: decimal_to_money(&va.available_balance, &va.currency),
                    held_amount: decimal_to_money(&va.held_amount, &va.currency),
                    currency: va.currency.clone(),
                    target_amount: decimal_to_money(&va.target_amount, &va.currency),
                    target_date: va.target_date.map(chrono_to_prost),
                    progress_percentage: va.progress_percentage,
                    auto_sweep_enabled: va.auto_sweep_enabled,
                    opened_at: Some(chrono_to_prost(va.opened_at)),
                    closed_at: va.closed_at.map(chrono_to_prost),
                    matured_at: va.matured_at.map(chrono_to_prost),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(VirtualAccount {
                        virtual_account_id: req.virtual_account_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_virtual_accounts(
        &self,
        request: Request<ListVirtualAccountsRequest>,
    ) -> Result<Response<ListVirtualAccountsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_virtual_accounts"));

        async {
            info!(trace_id = %trace_id, "Processing list_virtual_accounts request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let parent_account_id = if req.parent_account_id.is_empty() {
                None
            } else {
                Some(parse_uuid(&req.parent_account_id)?)
            };
            let types: Vec<VirtualAccountType> = req.types.iter().filter_map(|&t| map_proto_virtual_account_type(t)).collect();
            let statuses: Vec<VirtualAccountStatus> = req.statuses.iter().filter_map(|&s| map_proto_virtual_account_status(s)).collect();
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_virtual_accounts(tenant_id, parent_account_id, types, statuses, pagination).await {
                Ok((accounts, meta)) => {
                    let vas = accounts.into_iter().map(|va| VirtualAccount {
                        virtual_account_id: va.virtual_account_id.to_string(),
                        parent_account_id: va.parent_account_id.to_string(),
                        virtual_account_name: va.virtual_account_name,
                        virtual_account_number: va.virtual_account_number,
                        virtual_account_type: map_domain_virtual_account_type(va.virtual_account_type),
                        status: map_domain_virtual_account_status(va.status),
                        current_balance: decimal_to_money(&va.current_balance, &va.currency),
                        available_balance: decimal_to_money(&va.available_balance, &va.currency),
                        held_amount: decimal_to_money(&va.held_amount, &va.currency),
                        currency: va.currency.clone(),
                        target_amount: decimal_to_money(&va.target_amount, &va.currency),
                        target_date: va.target_date.map(chrono_to_prost),
                        progress_percentage: va.progress_percentage,
                        auto_sweep_enabled: va.auto_sweep_enabled,
                        opened_at: Some(chrono_to_prost(va.opened_at)),
                        closed_at: va.closed_at.map(chrono_to_prost),
                        matured_at: va.matured_at.map(chrono_to_prost),
                        error: None,
                    }).collect();
                    Ok(Response::new(ListVirtualAccountsResponse {
                        virtual_accounts: vas,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListVirtualAccountsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_virtual_account_summary(
        &self,
        request: Request<GetVirtualAccountSummaryRequest>,
    ) -> Result<Response<GetVirtualAccountSummaryResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_virtual_account_summary"));

        async {
            info!(trace_id = %trace_id, "Processing get_virtual_account_summary request");
            let req = request.into_inner();
            let parent_account_id = parse_uuid(&req.parent_account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_virtual_account_summary(parent_account_id, tenant_id).await {
                Ok(summaries) => Ok(Response::new(GetVirtualAccountSummaryResponse {
                    parent_account_id: req.parent_account_id,
                    summaries: summaries.into_iter().map(|s| VirtualAccountCurrencySummary {
                        currency: s.currency.clone(),
                        total_balance: decimal_to_money(&s.total_balance, &s.currency),
                        total_available: decimal_to_money(&s.total_available, &s.currency),
                        total_held: decimal_to_money(&s.total_held, &s.currency),
                        account_count: s.account_count,
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetVirtualAccountSummaryResponse {
                        parent_account_id: req.parent_account_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_virtual_account_transactions(
        &self,
        request: Request<GetVirtualAccountTransactionsRequest>,
    ) -> Result<Response<ListTransactionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_virtual_account_transactions"));

        async {
            info!(trace_id = %trace_id, "Processing get_virtual_account_transactions request");
            let req = request.into_inner();
            let virtual_account_id = parse_uuid(&req.virtual_account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let from = prost_to_chrono(req.from_date)
                .ok_or_else(|| Status::invalid_argument("from_date is required"))?;
            let to = prost_to_chrono(req.to_date)
                .ok_or_else(|| Status::invalid_argument("to_date is required"))?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.get_virtual_account_transactions(virtual_account_id, tenant_id, from, to, pagination).await {
                Ok((transactions, meta, total_count, credits, debits, fees)) => {
                    let txns = transactions.into_iter().map(map_domain_transaction).collect();
                    Ok(Response::new(ListTransactionsResponse {
                        transactions: txns,
                        pagination: Some(map_domain_pagination(&meta)),
                        total_count,
                        total_credits: decimal_to_money(&credits, "USD"),
                        total_debits: decimal_to_money(&debits, "USD"),
                        total_fees: decimal_to_money(&fees, "USD"),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListTransactionsResponse {
                        error: proto_err,
                        ..Default::default()
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

#[tonic::async_trait]
impl LiquidityPositionService for LedgerQueryGrpcServer {
    async fn get_liquidity_position(
        &self,
        request: Request<GetLiquidityPositionRequest>,
    ) -> Result<Response<LiquidityPosition>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_liquidity_position"));

        async {
            info!(trace_id = %trace_id, "Processing get_liquidity_position request");
            let req = request.into_inner();
            let position_id = parse_uuid(&req.position_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_liquidity_position(position_id, tenant_id).await {
                Ok(pos) => Ok(Response::new(LiquidityPosition {
                    position_id: pos.position_id.to_string(),
                    position_reference: pos.position_reference,
                    account_id: pos.account_id.to_string(),
                    tenant_id: pos.tenant_id.to_string(),
                    position_type: map_domain_liquidity_position_type(pos.position_type),
                    amount: decimal_to_money(&pos.amount, &pos.currency),
                    currency: pos.currency,
                    status: map_domain_liquidity_position_status(pos.status),
                    purpose_code: pos.purpose_code,
                    description: pos.description,
                    created_at: Some(chrono_to_prost(pos.created_at)),
                    effective_date: Some(chrono_to_prost(pos.effective_date)),
                    expires_at: pos.expires_at.map(chrono_to_prost),
                    released_at: pos.released_at.map(chrono_to_prost),
                    auto_release: pos.auto_release,
                    release_reason: pos.release_reason,
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(LiquidityPosition {
                        position_id: req.position_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_liquidity_positions(
        &self,
        request: Request<ListLiquidityPositionsRequest>,
    ) -> Result<Response<ListLiquidityPositionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_liquidity_positions"));

        async {
            info!(trace_id = %trace_id, "Processing list_liquidity_positions request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let account_id = if req.account_id.is_empty() {
                None
            } else {
                Some(parse_uuid(&req.account_id)?)
            };
            let types: Vec<LiquidityPositionType> = req.types.iter().filter_map(|&t| map_proto_liquidity_position_type(t)).collect();
            let statuses: Vec<LiquidityPositionStatus> = req.statuses.iter().filter_map(|&s| map_proto_liquidity_position_status(s)).collect();
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_liquidity_positions(tenant_id, account_id, types, statuses, pagination).await {
                Ok((positions, meta)) => {
                    let pps = positions.into_iter().map(|pos| LiquidityPosition {
                        position_id: pos.position_id.to_string(),
                        position_reference: pos.position_reference,
                        account_id: pos.account_id.to_string(),
                        tenant_id: pos.tenant_id.to_string(),
                        position_type: map_domain_liquidity_position_type(pos.position_type),
                        amount: decimal_to_money(&pos.amount, &pos.currency),
                        currency: pos.currency,
                        status: map_domain_liquidity_position_status(pos.status),
                        purpose_code: pos.purpose_code,
                        description: pos.description,
                        created_at: Some(chrono_to_prost(pos.created_at)),
                        effective_date: Some(chrono_to_prost(pos.effective_date)),
                        expires_at: pos.expires_at.map(chrono_to_prost),
                        released_at: pos.released_at.map(chrono_to_prost),
                        auto_release: pos.auto_release,
                        release_reason: pos.release_reason,
                        error: None,
                    }).collect();
                    Ok(Response::new(ListLiquidityPositionsResponse {
                        positions: pps,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListLiquidityPositionsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_liquidity_summary(
        &self,
        request: Request<GetLiquiditySummaryRequest>,
    ) -> Result<Response<GetLiquiditySummaryResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_liquidity_summary"));

        async {
            info!(trace_id = %trace_id, "Processing get_liquidity_summary request");
            let req = request.into_inner();
            let account_id = parse_uuid(&req.account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_liquidity_summary(account_id, tenant_id).await {
                Ok(items) => Ok(Response::new(GetLiquiditySummaryResponse {
                    account_id: req.account_id,
                    items: items.into_iter().map(|i| LiquiditySummaryItem {
                        position_type: map_domain_liquidity_position_type(i.position_type),
                        currency: i.currency.clone(),
                        total_amount: decimal_to_money(&i.total_amount, &i.currency),
                        position_count: i.position_count,
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetLiquiditySummaryResponse {
                        account_id: req.account_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_expiring_positions(
        &self,
        request: Request<GetExpiringPositionsRequest>,
    ) -> Result<Response<GetExpiringPositionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_expiring_positions"));

        async {
            info!(trace_id = %trace_id, "Processing get_expiring_positions request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let lookahead_minutes = req.lookahead_minutes;

            match self.handler.get_expiring_positions(tenant_id, lookahead_minutes).await {
                Ok(positions) => Ok(Response::new(GetExpiringPositionsResponse {
                    positions: positions.into_iter().map(|p| ExpiringPosition {
                        position_id: p.position_id.to_string(),
                        account_id: p.account_id.to_string(),
                        position_type: map_domain_liquidity_position_type(p.position_type),
                        amount: decimal_to_money(&p.amount, &p.currency),
                        currency: p.currency,
                        expires_at: Some(chrono_to_prost(p.expires_at)),
                        minutes_until_expiry: p.minutes_until_expiry,
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetExpiringPositionsResponse {
                        error: proto_err,
                        ..Default::default()
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

#[tonic::async_trait]
impl SettlementService for LedgerQueryGrpcServer {
    async fn get_settlement_instruction(
        &self,
        request: Request<GetSettlementInstructionRequest>,
    ) -> Result<Response<SettlementInstruction>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_settlement_instruction"));

        async {
            info!(trace_id = %trace_id, "Processing get_settlement_instruction request");
            let req = request.into_inner();
            let settlement_id = parse_uuid(&req.settlement_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_settlement_instruction(settlement_id, tenant_id).await {
                Ok(si) => Ok(Response::new(SettlementInstruction {
                    settlement_id: si.settlement_id.to_string(),
                    settlement_reference: si.settlement_reference,
                    tenant_id: si.tenant_id.to_string(),
                    counterparty_id: si.counterparty_id,
                    counterparty_name: si.counterparty_name,
                    settlement_type: map_domain_settlement_type(si.settlement_type),
                    direction: si.direction,
                    amount: decimal_to_money(&si.amount, &si.currency),
                    currency: si.currency.clone(),
                    status: map_domain_settlement_status(si.status),
                    scheduled_at: si.scheduled_at.map(chrono_to_prost),
                    settlement_date: si.settlement_date.map(chrono_to_prost),
                    executed_at: si.executed_at.map(chrono_to_prost),
                    completed_at: si.completed_at.map(chrono_to_prost),
                    settlement_account: si.settlement_account,
                    counterparty_account: si.counterparty_account,
                    transaction_count: si.transaction_count,
                    gross_amount: decimal_to_money(&si.gross_amount, &si.currency),
                    net_amount: decimal_to_money(&si.net_amount, &si.currency),
                    fees_amount: decimal_to_money(&si.fees_amount, &si.currency),
                    confirmation_reference: si.confirmation_reference,
                    failure_reason: si.failure_reason,
                    retry_count: si.retry_count,
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(SettlementInstruction {
                        settlement_id: req.settlement_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_settlement_instructions(
        &self,
        request: Request<ListSettlementInstructionsRequest>,
    ) -> Result<Response<ListSettlementInstructionsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_settlement_instructions"));

        async {
            info!(trace_id = %trace_id, "Processing list_settlement_instructions request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let settlement_type = if req.settlement_type == 0 {
                None
            } else {
                map_proto_settlement_type(req.settlement_type)
            };
            let statuses: Vec<SettlementStatus> = req.statuses.iter().filter_map(|&s| map_proto_settlement_status(s)).collect();
            let from = prost_to_chrono(req.from_date)
                .ok_or_else(|| Status::invalid_argument("from_date is required"))?;
            let to = prost_to_chrono(req.to_date)
                .ok_or_else(|| Status::invalid_argument("to_date is required"))?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_settlement_instructions(tenant_id, settlement_type, statuses, from, to, pagination).await {
                Ok((settlements, meta)) => {
                    let items = settlements.into_iter().map(|si| SettlementInstruction {
                        settlement_id: si.settlement_id.to_string(),
                        settlement_reference: si.settlement_reference,
                        tenant_id: si.tenant_id.to_string(),
                        counterparty_id: si.counterparty_id,
                        counterparty_name: si.counterparty_name,
                        settlement_type: map_domain_settlement_type(si.settlement_type),
                        direction: si.direction,
                        amount: decimal_to_money(&si.amount, &si.currency),
                        currency: si.currency.clone(),
                        status: map_domain_settlement_status(si.status),
                        scheduled_at: si.scheduled_at.map(chrono_to_prost),
                        settlement_date: si.settlement_date.map(chrono_to_prost),
                        executed_at: si.executed_at.map(chrono_to_prost),
                        completed_at: si.completed_at.map(chrono_to_prost),
                        settlement_account: si.settlement_account,
                        counterparty_account: si.counterparty_account,
                        transaction_count: si.transaction_count,
                        gross_amount: decimal_to_money(&si.gross_amount, &si.currency),
                        net_amount: decimal_to_money(&si.net_amount, &si.currency),
                        fees_amount: decimal_to_money(&si.fees_amount, &si.currency),
                        confirmation_reference: si.confirmation_reference,
                        failure_reason: si.failure_reason,
                        retry_count: si.retry_count,
                        error: None,
                    }).collect();
                    Ok(Response::new(ListSettlementInstructionsResponse {
                        settlements: items,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListSettlementInstructionsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_pending_settlements(
        &self,
        request: Request<GetPendingSettlementsRequest>,
    ) -> Result<Response<GetPendingSettlementsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_pending_settlements"));

        async {
            info!(trace_id = %trace_id, "Processing get_pending_settlements request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_pending_settlements(tenant_id).await {
                Ok(settlements) => Ok(Response::new(GetPendingSettlementsResponse {
                    settlements: settlements.into_iter().map(|si| SettlementInstruction {
                        settlement_id: si.settlement_id.to_string(),
                        settlement_reference: si.settlement_reference,
                        tenant_id: si.tenant_id.to_string(),
                        counterparty_id: si.counterparty_id,
                        counterparty_name: si.counterparty_name,
                        settlement_type: map_domain_settlement_type(si.settlement_type),
                        direction: si.direction,
                        amount: decimal_to_money(&si.amount, &si.currency),
                        currency: si.currency.clone(),
                        status: map_domain_settlement_status(si.status),
                        scheduled_at: si.scheduled_at.map(chrono_to_prost),
                        settlement_date: si.settlement_date.map(chrono_to_prost),
                        executed_at: si.executed_at.map(chrono_to_prost),
                        completed_at: si.completed_at.map(chrono_to_prost),
                        settlement_account: si.settlement_account,
                        counterparty_account: si.counterparty_account,
                        transaction_count: si.transaction_count,
                        gross_amount: decimal_to_money(&si.gross_amount, &si.currency),
                        net_amount: decimal_to_money(&si.net_amount, &si.currency),
                        fees_amount: decimal_to_money(&si.fees_amount, &si.currency),
                        confirmation_reference: si.confirmation_reference,
                        failure_reason: si.failure_reason,
                        retry_count: si.retry_count,
                        error: None,
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetPendingSettlementsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_settlement_summary(
        &self,
        request: Request<GetSettlementSummaryRequest>,
    ) -> Result<Response<GetSettlementSummaryResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_settlement_summary"));

        async {
            info!(trace_id = %trace_id, "Processing get_settlement_summary request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let start_date = prost_to_chrono(req.start_date)
                .ok_or_else(|| Status::invalid_argument("start_date is required"))?;
            let end_date = prost_to_chrono(req.end_date)
                .ok_or_else(|| Status::invalid_argument("end_date is required"))?;

            match self.handler.get_settlement_summary(tenant_id, start_date, end_date).await {
                Ok(items) => Ok(Response::new(GetSettlementSummaryResponse {
                    items: items.into_iter().map(|i| SettlementSummaryItem {
                        settlement_type: map_domain_settlement_type(i.settlement_type),
                        direction: i.direction,
                        currency: i.currency.clone(),
                        total_amount: decimal_to_money(&i.total_amount, &i.currency),
                        count: i.count,
                        completed_count: i.completed_count,
                        failed_count: i.failed_count,
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetSettlementSummaryResponse {
                        error: proto_err,
                        ..Default::default()
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

#[tonic::async_trait]
impl SuspenseService for LedgerQueryGrpcServer {
    async fn get_suspense_item(
        &self,
        request: Request<GetSuspenseItemRequest>,
    ) -> Result<Response<SuspenseItem>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_suspense_item"));

        async {
            info!(trace_id = %trace_id, "Processing get_suspense_item request");
            let req = request.into_inner();
            let suspense_id = parse_uuid(&req.suspense_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_suspense_item(suspense_id, tenant_id).await {
                Ok(item) => Ok(Response::new(SuspenseItem {
                    suspense_id: item.suspense_id.to_string(),
                    suspense_reference: item.suspense_reference,
                    source_transaction_id: item.source_transaction_id,
                    amount: decimal_to_money(&item.amount, &item.currency),
                    currency: item.currency,
                    category: map_domain_suspense_category(item.category),
                    priority: item.priority,
                    status: map_domain_suspense_status(item.status),
                    description: item.description,
                    days_in_suspense: item.days_in_suspense,
                    escalation_level: item.escalation_level,
                    resolution_type: item.resolution_type.map(map_domain_suspense_resolution_type).unwrap_or_default(),
                    resolution_date: item.resolution_date.map(chrono_to_prost),
                    resolution_notes: item.resolution_notes,
                    created_at: Some(chrono_to_prost(item.created_at)),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(SuspenseItem {
                        suspense_id: req.suspense_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_suspense_items(
        &self,
        request: Request<ListSuspenseItemsRequest>,
    ) -> Result<Response<ListSuspenseItemsResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_suspense_items"));

        async {
            info!(trace_id = %trace_id, "Processing list_suspense_items request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let statuses: Vec<SuspenseStatus> = req.statuses.iter().filter_map(|&s| map_proto_suspense_status(s)).collect();
            let categories: Vec<SuspenseCategory> = req.categories.iter().filter_map(|&c| map_proto_suspense_category(c)).collect();
            let priority = if req.priority.is_empty() { None } else { Some(req.priority) };
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_suspense_items(tenant_id, statuses, categories, priority, pagination).await {
                Ok((items, meta)) => {
                    let its = items.into_iter().map(|item| SuspenseItem {
                        suspense_id: item.suspense_id.to_string(),
                        suspense_reference: item.suspense_reference,
                        source_transaction_id: item.source_transaction_id,
                        amount: decimal_to_money(&item.amount, &item.currency),
                        currency: item.currency,
                        category: map_domain_suspense_category(item.category),
                        priority: item.priority,
                        status: map_domain_suspense_status(item.status),
                        description: item.description,
                        days_in_suspense: item.days_in_suspense,
                        escalation_level: item.escalation_level,
                        resolution_type: item.resolution_type.map(map_domain_suspense_resolution_type).unwrap_or_default(),
                        resolution_date: item.resolution_date.map(chrono_to_prost),
                        resolution_notes: item.resolution_notes,
                        created_at: Some(chrono_to_prost(item.created_at)),
                        error: None,
                    }).collect();
                    Ok(Response::new(ListSuspenseItemsResponse {
                        items: its,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListSuspenseItemsResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_suspense_aging_report(
        &self,
        request: Request<GetSuspenseAgingReportRequest>,
    ) -> Result<Response<GetSuspenseAgingReportResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_suspense_aging_report"));

        async {
            info!(trace_id = %trace_id, "Processing get_suspense_aging_report request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_suspense_aging_report(tenant_id).await {
                Ok(buckets) => Ok(Response::new(GetSuspenseAgingReportResponse {
                    buckets: buckets.into_iter().map(|b| SuspenseAgingBucket {
                        category: b.category,
                        days_range_start: b.days_range_start,
                        days_range_end: b.days_range_end,
                        count: b.count,
                        total_amount: decimal_to_money(&b.total_amount, "USD"),
                    }).collect(),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetSuspenseAgingReportResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_suspense_activity_log(
        &self,
        request: Request<GetSuspenseActivityLogRequest>,
    ) -> Result<Response<GetSuspenseActivityLogResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_suspense_activity_log"));

        async {
            info!(trace_id = %trace_id, "Processing get_suspense_activity_log request");
            let req = request.into_inner();
            let suspense_id = parse_uuid(&req.suspense_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.get_suspense_activity_log(suspense_id, tenant_id, pagination).await {
                Ok((entries, meta)) => Ok(Response::new(GetSuspenseActivityLogResponse {
                    entries: entries.into_iter().map(|e| SuspenseActivityEntry {
                        activity_id: e.activity_id,
                        suspense_id: e.suspense_id,
                        activity_type: e.activity_type,
                        from_status: e.from_status,
                        to_status: e.to_status,
                        performed_by: e.performed_by,
                        notes: e.notes,
                        created_at: Some(chrono_to_prost(e.created_at)),
                    }).collect(),
                    pagination: Some(map_domain_pagination(&meta)),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(GetSuspenseActivityLogResponse {
                        error: proto_err,
                        ..Default::default()
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

#[tonic::async_trait]
impl ChartOfAccountsService for LedgerQueryGrpcServer {
    async fn get_coa_entry(
        &self,
        request: Request<GetCoaEntryRequest>,
    ) -> Result<Response<CoaEntry>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_coa_entry"));

        async {
            info!(trace_id = %trace_id, "Processing get_coa_entry request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_coa_entry(&req.coa_code, tenant_id).await {
                Ok(entry) => Ok(Response::new(CoaEntry {
                    coa_code: entry.coa_code,
                    tenant_id: entry.tenant_id.to_string(),
                    account_name: entry.account_name,
                    account_category: entry.account_category,
                    parent_code: entry.parent_code,
                    level: entry.level,
                    is_leaf: entry.is_leaf,
                    normal_balance: entry.normal_balance,
                    is_active: entry.is_active,
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(CoaEntry {
                        coa_code: req.coa_code,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_coa_entries(
        &self,
        request: Request<ListCoaEntriesRequest>,
    ) -> Result<Response<ListCoaEntriesResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_coa_entries"));

        async {
            info!(trace_id = %trace_id, "Processing list_coa_entries request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let parent_code = if req.parent_code.is_empty() { None } else { Some(req.parent_code) };
            let account_category = if req.account_category.is_empty() { None } else { Some(req.account_category) };
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_coa_entries(tenant_id, parent_code, account_category, pagination).await {
                Ok((entries, meta)) => {
                    let ens = entries.into_iter().map(|entry| CoaEntry {
                        coa_code: entry.coa_code,
                        tenant_id: entry.tenant_id.to_string(),
                        account_name: entry.account_name,
                        account_category: entry.account_category,
                        parent_code: entry.parent_code,
                        level: entry.level,
                        is_leaf: entry.is_leaf,
                        normal_balance: entry.normal_balance,
                        is_active: entry.is_active,
                        error: None,
                    }).collect();
                    Ok(Response::new(ListCoaEntriesResponse {
                        entries: ens,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListCoaEntriesResponse {
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_period_end_balance(
        &self,
        request: Request<GetPeriodEndBalanceRequest>,
    ) -> Result<Response<PeriodEndBalance>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("get_period_end_balance"));

        async {
            info!(trace_id = %trace_id, "Processing get_period_end_balance request");
            let req = request.into_inner();
            let account_id = parse_uuid(&req.account_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            match self.handler.get_period_end_balance(account_id, tenant_id, &req.fiscal_period_id).await {
                Ok(bal) => Ok(Response::new(PeriodEndBalance {
                    balance_id: bal.balance_id,
                    account_id: bal.account_id.to_string(),
                    tenant_id: bal.tenant_id.to_string(),
                    fiscal_period_id: bal.fiscal_period_id,
                    opening_balance: decimal_to_money(&bal.opening_balance, &bal.currency),
                    closing_balance: decimal_to_money(&bal.closing_balance, &bal.currency),
                    total_debits: decimal_to_money(&bal.total_debits, &bal.currency),
                    total_credits: decimal_to_money(&bal.total_credits, &bal.currency),
                    currency: bal.currency,
                    is_adjusted: bal.is_adjusted,
                    created_at: Some(chrono_to_prost(bal.created_at)),
                    error: None,
                })),
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(PeriodEndBalance {
                        balance_id: String::new(),
                        account_id: req.account_id,
                        tenant_id: req.tenant_id,
                        fiscal_period_id: req.fiscal_period_id,
                        error: proto_err,
                        ..Default::default()
                    }))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn list_period_end_balances(
        &self,
        request: Request<ListPeriodEndBalancesRequest>,
    ) -> Result<Response<ListPeriodEndBalancesResponse>, Status> {
        let trace_id = extract_trace_id(&request);
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("list_period_end_balances"));

        async {
            info!(trace_id = %trace_id, "Processing list_period_end_balances request");
            let req = request.into_inner();
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let pagination = map_proto_pagination(req.pagination);

            match self.handler.list_period_end_balances(tenant_id, &req.fiscal_period_id, pagination).await {
                Ok((balances, meta)) => {
                    let bs = balances.into_iter().map(|bal| PeriodEndBalance {
                        balance_id: bal.balance_id,
                        account_id: bal.account_id.to_string(),
                        tenant_id: bal.tenant_id.to_string(),
                        fiscal_period_id: bal.fiscal_period_id,
                        opening_balance: decimal_to_money(&bal.opening_balance, &bal.currency),
                        closing_balance: decimal_to_money(&bal.closing_balance, &bal.currency),
                        total_debits: decimal_to_money(&bal.total_debits, &bal.currency),
                        total_credits: decimal_to_money(&bal.total_credits, &bal.currency),
                        currency: bal.currency,
                        is_adjusted: bal.is_adjusted,
                        created_at: Some(chrono_to_prost(bal.created_at)),
                        error: None,
                    }).collect();
                    Ok(Response::new(ListPeriodEndBalancesResponse {
                        balances: bs,
                        pagination: Some(map_domain_pagination(&meta)),
                        error: None,
                    }))
                }
                Err(e) => {
                    let (_status, proto_err) = self.map_error(e, &trace_id);
                    Ok(Response::new(ListPeriodEndBalancesResponse {
                        error: proto_err,
                        ..Default::default()
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
