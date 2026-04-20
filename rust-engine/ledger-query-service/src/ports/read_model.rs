use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::account::{AccountBalance, AccountSummary};
use crate::domain::coa::{COAEntry, PeriodEndBalance};
use crate::domain::error::LedgerQueryError;
use crate::domain::liquidity::{
    ExpiringPosition, LiquidityPosition, LiquidityPositionStatus, LiquidityPositionType,
    LiquiditySummaryItem,
};
use crate::domain::pagination::{Pagination, PaginationMetadata};
use crate::domain::settlement::{
    SettlementInstruction, SettlementStatus, SettlementSummaryItem, SettlementType,
};
use crate::domain::suspense::{
    SuspenseActivityEntry, SuspenseAgingBucket, SuspenseCategory, SuspenseItem, SuspenseStatus,
};
use crate::domain::transaction::{MovementLeg, Transaction, TransactionType};
use crate::domain::virtual_account::{
    VirtualAccount, VirtualAccountCurrencySummary, VirtualAccountStatus, VirtualAccountType,
};

#[async_trait]
pub trait ReadModelPort: Send + Sync {
    // LedgerQueryService
    async fn get_account_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountBalance, LedgerQueryError>;
    async fn get_account_statement(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<
        (
            Vec<Transaction>,
            PaginationMetadata,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
            Decimal,
        ),
        LedgerQueryError,
    >;
    async fn get_transaction_by_id(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Transaction, LedgerQueryError>;
    async fn list_transactions(
        &self,
        tenant_id: Uuid,
        account_ids: Vec<Uuid>,
        types: Vec<TransactionType>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>;
    async fn search_transactions(
        &self,
        tenant_id: Uuid,
        query: &str,
        filters: Option<serde_json::Value>,
        pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>;
    async fn get_account_summary(
        &self,
        tenant_id: Uuid,
        as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountSummary, LedgerQueryError>;
    async fn get_movement_legs(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<MovementLeg>, LedgerQueryError>;
    async fn verify_double_entry(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<(bool, Decimal, Decimal, Decimal), LedgerQueryError>;

    // VirtualAccountService
    async fn get_virtual_account(
        &self,
        virtual_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<VirtualAccount, LedgerQueryError>;
    async fn list_virtual_accounts(
        &self,
        tenant_id: Uuid,
        parent_account_id: Option<Uuid>,
        types: Vec<VirtualAccountType>,
        statuses: Vec<VirtualAccountStatus>,
        pagination: Pagination,
    ) -> Result<(Vec<VirtualAccount>, PaginationMetadata), LedgerQueryError>;
    async fn get_virtual_account_summary(
        &self,
        parent_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<VirtualAccountCurrencySummary>, LedgerQueryError>;

    // LiquidityPositionService
    async fn get_liquidity_position(
        &self,
        position_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<LiquidityPosition, LedgerQueryError>;
    async fn list_liquidity_positions(
        &self,
        tenant_id: Uuid,
        account_id: Option<Uuid>,
        types: Vec<LiquidityPositionType>,
        statuses: Vec<LiquidityPositionStatus>,
        pagination: Pagination,
    ) -> Result<(Vec<LiquidityPosition>, PaginationMetadata), LedgerQueryError>;
    async fn get_liquidity_summary(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<LiquiditySummaryItem>, LedgerQueryError>;
    async fn get_expiring_positions(
        &self,
        tenant_id: Uuid,
        lookahead_minutes: i32,
    ) -> Result<Vec<ExpiringPosition>, LedgerQueryError>;

    // SettlementService
    async fn get_settlement_instruction(
        &self,
        settlement_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SettlementInstruction, LedgerQueryError>;
    async fn list_settlement_instructions(
        &self,
        tenant_id: Uuid,
        settlement_type: Option<SettlementType>,
        statuses: Vec<SettlementStatus>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<(Vec<SettlementInstruction>, PaginationMetadata), LedgerQueryError>;
    async fn get_pending_settlements(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SettlementInstruction>, LedgerQueryError>;
    async fn get_settlement_summary(
        &self,
        tenant_id: Uuid,
        start_date: DateTime<Utc>,
        end_date: DateTime<Utc>,
    ) -> Result<Vec<SettlementSummaryItem>, LedgerQueryError>;

    // SuspenseService
    async fn get_suspense_item(
        &self,
        suspense_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SuspenseItem, LedgerQueryError>;
    async fn list_suspense_items(
        &self,
        tenant_id: Uuid,
        statuses: Vec<SuspenseStatus>,
        categories: Vec<SuspenseCategory>,
        priority: Option<&str>,
        pagination: Pagination,
    ) -> Result<(Vec<SuspenseItem>, PaginationMetadata), LedgerQueryError>;
    async fn get_suspense_aging_report(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SuspenseAgingBucket>, LedgerQueryError>;
    async fn get_suspense_activity_log(
        &self,
        suspense_id: Uuid,
        tenant_id: Uuid,
        pagination: Pagination,
    ) -> Result<(Vec<SuspenseActivityEntry>, PaginationMetadata), LedgerQueryError>;

    // ChartOfAccountsService
    async fn get_coa_entry(
        &self,
        coa_code: &str,
        tenant_id: Uuid,
    ) -> Result<COAEntry, LedgerQueryError>;
    async fn list_coa_entries(
        &self,
        tenant_id: Uuid,
        parent_code: Option<&str>,
        account_category: Option<&str>,
        pagination: Pagination,
    ) -> Result<(Vec<COAEntry>, PaginationMetadata), LedgerQueryError>;
    async fn get_period_end_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        fiscal_period_id: &str,
    ) -> Result<PeriodEndBalance, LedgerQueryError>;
    async fn list_period_end_balances(
        &self,
        tenant_id: Uuid,
        fiscal_period_id: &str,
        pagination: Pagination,
    ) -> Result<(Vec<PeriodEndBalance>, PaginationMetadata), LedgerQueryError>;
}
