use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::account::{AccountBalance, AccountSummary};
use crate::domain::coa::{COAEntry, PeriodEndBalance};
use crate::domain::error::LedgerQueryError;
use crate::domain::liquidity::{
    ExpiringPosition, LiquidityPosition, LiquiditySummaryItem,
};
use crate::domain::pagination::{Pagination, PaginationMetadata};
use crate::domain::settlement::{SettlementInstruction, SettlementSummaryItem};
use crate::domain::suspense::{
    SuspenseActivityEntry, SuspenseAgingBucket, SuspenseItem,
};
use crate::domain::transaction::{MovementLeg, Transaction, TransactionType};
use crate::domain::virtual_account::{
    VirtualAccount, VirtualAccountCurrencySummary, VirtualAccountStatus, VirtualAccountType,
};
use crate::ports::read_model::ReadModelPort;

#[derive(Clone)]
pub struct LedgerQueryHandler {
    read_model: Arc<dyn ReadModelPort>,
}

impl LedgerQueryHandler {
    pub fn new(read_model: Arc<dyn ReadModelPort>) -> Self {
        Self { read_model }
    }

    // LedgerQueryService
    pub async fn get_account_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountBalance, LedgerQueryError> {
        self.read_model
            .get_account_balance(account_id, tenant_id, as_of)
            .await
    }

    pub async fn get_account_statement(
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
    > {
        self.read_model
            .get_account_statement(account_id, tenant_id, from, to, pagination)
            .await
    }

    pub async fn get_transaction_by_id(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Transaction, LedgerQueryError> {
        self.read_model
            .get_transaction_by_id(transaction_id, tenant_id)
            .await
    }

    pub async fn list_transactions(
        &self,
        tenant_id: Uuid,
        account_ids: Vec<Uuid>,
        types: Vec<TransactionType>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>
    {
        self.read_model
            .list_transactions(tenant_id, account_ids, types, from, to, pagination)
            .await
    }

    pub async fn search_transactions(
        &self,
        tenant_id: Uuid,
        query: &str,
        filters: Option<serde_json::Value>,
        pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>
    {
        self.read_model
            .search_transactions(tenant_id, query, filters, pagination)
            .await
    }

    pub async fn get_account_summary(
        &self,
        tenant_id: Uuid,
        as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountSummary, LedgerQueryError> {
        self.read_model.get_account_summary(tenant_id, as_of).await
    }

    pub async fn rebuild_account_view(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        _dry_run: bool,
    ) -> Result<(bool, i64, rust_decimal::Decimal), LedgerQueryError> {
        // In a real implementation, this would replay events to rebuild the view.
        // For the read-side query service, we return a stub success.
        let balance = self
            .read_model
            .get_account_balance(account_id, tenant_id, None)
            .await?;
        Ok((true, 0, balance.current_balance))
    }

    pub async fn get_movement_legs(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<MovementLeg>, LedgerQueryError> {
        self.read_model
            .get_movement_legs(transaction_id, tenant_id)
            .await
    }

    pub async fn verify_double_entry(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<(bool, Decimal, Decimal, Decimal), LedgerQueryError> {
        self.read_model
            .verify_double_entry(transaction_id, tenant_id)
            .await
    }

    // VirtualAccountService
    pub async fn get_virtual_account(
        &self,
        virtual_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<VirtualAccount, LedgerQueryError> {
        self.read_model
            .get_virtual_account(virtual_account_id, tenant_id)
            .await
    }

    pub async fn list_virtual_accounts(
        &self,
        tenant_id: Uuid,
        parent_account_id: Option<Uuid>,
        types: Vec<VirtualAccountType>,
        statuses: Vec<VirtualAccountStatus>,
        pagination: Pagination,
    ) -> Result<(Vec<VirtualAccount>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_virtual_accounts(tenant_id, parent_account_id, types, statuses, pagination)
            .await
    }

    pub async fn get_virtual_account_summary(
        &self,
        parent_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<VirtualAccountCurrencySummary>, LedgerQueryError> {
        self.read_model
            .get_virtual_account_summary(parent_account_id, tenant_id)
            .await
    }

    pub async fn get_virtual_account_transactions(
        &self,
        virtual_account_id: Uuid,
        tenant_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>
    {
        // Query transactions for the virtual account via the underlying account linkage
        self.read_model
            .list_transactions(tenant_id, vec![virtual_account_id], vec![], from, to, pagination)
            .await
    }

    // LiquidityPositionService
    pub async fn get_liquidity_position(
        &self,
        position_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<LiquidityPosition, LedgerQueryError> {
        self.read_model
            .get_liquidity_position(position_id, tenant_id)
            .await
    }

    pub async fn list_liquidity_positions(
        &self,
        tenant_id: Uuid,
        account_id: Option<Uuid>,
        types: Vec<crate::domain::liquidity::LiquidityPositionType>,
        statuses: Vec<crate::domain::liquidity::LiquidityPositionStatus>,
        pagination: Pagination,
    ) -> Result<(Vec<LiquidityPosition>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_liquidity_positions(tenant_id, account_id, types, statuses, pagination)
            .await
    }

    pub async fn get_liquidity_summary(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<LiquiditySummaryItem>, LedgerQueryError> {
        self.read_model
            .get_liquidity_summary(account_id, tenant_id)
            .await
    }

    pub async fn get_expiring_positions(
        &self,
        tenant_id: Uuid,
        lookahead_minutes: i32,
    ) -> Result<Vec<ExpiringPosition>, LedgerQueryError> {
        self.read_model
            .get_expiring_positions(tenant_id, lookahead_minutes)
            .await
    }

    // SettlementService
    pub async fn get_settlement_instruction(
        &self,
        settlement_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SettlementInstruction, LedgerQueryError> {
        self.read_model
            .get_settlement_instruction(settlement_id, tenant_id)
            .await
    }

    pub async fn list_settlement_instructions(
        &self,
        tenant_id: Uuid,
        settlement_type: Option<crate::domain::settlement::SettlementType>,
        statuses: Vec<crate::domain::settlement::SettlementStatus>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        pagination: Pagination,
    ) -> Result<(Vec<SettlementInstruction>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_settlement_instructions(tenant_id, settlement_type, statuses, from, to, pagination)
            .await
    }

    pub async fn get_pending_settlements(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SettlementInstruction>, LedgerQueryError> {
        self.read_model.get_pending_settlements(tenant_id).await
    }

    pub async fn get_settlement_summary(
        &self,
        tenant_id: Uuid,
        start_date: DateTime<Utc>,
        end_date: DateTime<Utc>,
    ) -> Result<Vec<SettlementSummaryItem>, LedgerQueryError> {
        self.read_model
            .get_settlement_summary(tenant_id, start_date, end_date)
            .await
    }

    // SuspenseService
    pub async fn get_suspense_item(
        &self,
        suspense_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SuspenseItem, LedgerQueryError> {
        self.read_model.get_suspense_item(suspense_id, tenant_id).await
    }

    pub async fn list_suspense_items(
        &self,
        tenant_id: Uuid,
        statuses: Vec<crate::domain::suspense::SuspenseStatus>,
        categories: Vec<crate::domain::suspense::SuspenseCategory>,
        priority: Option<String>,
        pagination: Pagination,
    ) -> Result<(Vec<SuspenseItem>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_suspense_items(
                tenant_id,
                statuses,
                categories,
                priority.as_deref(),
                pagination,
            )
            .await
    }

    pub async fn get_suspense_aging_report(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SuspenseAgingBucket>, LedgerQueryError> {
        self.read_model.get_suspense_aging_report(tenant_id).await
    }

    pub async fn get_suspense_activity_log(
        &self,
        suspense_id: Uuid,
        tenant_id: Uuid,
        pagination: Pagination,
    ) -> Result<(Vec<SuspenseActivityEntry>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .get_suspense_activity_log(suspense_id, tenant_id, pagination)
            .await
    }

    // ChartOfAccountsService
    pub async fn get_coa_entry(
        &self,
        coa_code: &str,
        tenant_id: Uuid,
    ) -> Result<COAEntry, LedgerQueryError> {
        self.read_model.get_coa_entry(coa_code, tenant_id).await
    }

    pub async fn list_coa_entries(
        &self,
        tenant_id: Uuid,
        parent_code: Option<String>,
        account_category: Option<String>,
        pagination: Pagination,
    ) -> Result<(Vec<COAEntry>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_coa_entries(
                tenant_id,
                parent_code.as_deref(),
                account_category.as_deref(),
                pagination,
            )
            .await
    }

    pub async fn get_period_end_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        fiscal_period_id: &str,
    ) -> Result<PeriodEndBalance, LedgerQueryError> {
        self.read_model
            .get_period_end_balance(account_id, tenant_id, fiscal_period_id)
            .await
    }

    pub async fn list_period_end_balances(
        &self,
        tenant_id: Uuid,
        fiscal_period_id: &str,
        pagination: Pagination,
    ) -> Result<(Vec<PeriodEndBalance>, PaginationMetadata), LedgerQueryError> {
        self.read_model
            .list_period_end_balances(tenant_id, fiscal_period_id, pagination)
            .await
    }
}
