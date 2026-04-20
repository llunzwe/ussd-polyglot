use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::{Pool, Postgres};
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
use crate::ports::read_model::ReadModelPort;

#[derive(Debug, Clone)]
pub struct PostgresReadModel {
    pool: Pool<Postgres>,
}

impl PostgresReadModel {
    pub fn new(pool: Pool<Postgres>) -> Self {
        Self { pool }
    }

    async fn set_tenant(&self, tenant_id: Uuid) -> Result<(), LedgerQueryError> {
        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| LedgerQueryError::DatabaseError(e.to_string()))?;
        Ok(())
    }
}

#[async_trait]
impl ReadModelPort for PostgresReadModel {
    async fn get_account_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        _as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountBalance, LedgerQueryError> {
        let _sql = r#"
            SELECT account_id, tenant_id, account_type,
                   current_balance, available_balance, hold_balance,
                   currency_code, updated_at as as_of, version
            FROM core.account_registry
            WHERE account_id = $1 AND primary_application_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::AccountNotFound(account_id.to_string()))
    }

    async fn get_account_statement(
        &self,
        _account_id: Uuid,
        tenant_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        _pagination: Pagination,
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
        let _sql = r#"
            SELECT transaction_id, transaction_uuid, tenant_id, account_id,
                   transaction_type, amount, balance_after, description,
                   reference, posted_at, effective_at, session_id, payment_id,
                   metadata, version, correlation_id, idempotency_key,
                   status, record_hash, previous_hash
            FROM core.transaction_log
            WHERE initiator_account_id = $1 AND application_id = $2
              AND committed_at >= $3 AND committed_at <= $4
            ORDER BY committed_at DESC
            LIMIT $5 OFFSET $6
        "#;
        self.set_tenant(tenant_id).await?;
        if from > to {
            return Err(LedgerQueryError::InvalidDateRange(
                "from_date must be before to_date".to_string(),
            ));
        }
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
            Decimal::ZERO,
            Decimal::ZERO,
            Decimal::ZERO,
            Decimal::ZERO,
            Decimal::ZERO,
        ))
    }

    async fn get_transaction_by_id(
        &self,
        transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Transaction, LedgerQueryError> {
        let _sql = r#"
            SELECT transaction_id, transaction_uuid, tenant_id, account_id,
                   transaction_type, amount, balance_after, description,
                   reference, posted_at, effective_at, session_id, payment_id,
                   metadata, version, correlation_id, idempotency_key,
                   status, record_hash, previous_hash
            FROM core.transaction_log
            WHERE transaction_uuid = $1 AND application_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::TransactionNotFound(
            transaction_id.to_string(),
        ))
    }

    async fn list_transactions(
        &self,
        tenant_id: Uuid,
        _account_ids: Vec<Uuid>,
        _types: Vec<TransactionType>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        _pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>
    {
        let _sql = r#"
            SELECT transaction_id, transaction_uuid, tenant_id, account_id,
                   transaction_type, amount, balance_after, description,
                   reference, posted_at, effective_at, session_id, payment_id,
                   metadata, version, correlation_id, idempotency_key,
                   status, record_hash, previous_hash
            FROM core.transaction_log
            WHERE application_id = $1
              AND committed_at >= $2 AND committed_at <= $3
            ORDER BY committed_at DESC
            LIMIT $4 OFFSET $5
        "#;
        self.set_tenant(tenant_id).await?;
        if from > to {
            return Err(LedgerQueryError::InvalidDateRange(
                "from_date must be before to_date".to_string(),
            ));
        }
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
            0,
            Decimal::ZERO,
            Decimal::ZERO,
            Decimal::ZERO,
        ))
    }

    async fn search_transactions(
        &self,
        tenant_id: Uuid,
        _query: &str,
        _filters: Option<serde_json::Value>,
        _pagination: Pagination,
    ) -> Result<(Vec<Transaction>, PaginationMetadata, i32, Decimal, Decimal, Decimal), LedgerQueryError>
    {
        let _sql = r#"
            SELECT transaction_id, transaction_uuid, tenant_id, account_id,
                   transaction_type, amount, balance_after, description,
                   reference, posted_at, effective_at, session_id, payment_id,
                   metadata, version, correlation_id, idempotency_key,
                   status, record_hash, previous_hash
            FROM core.transaction_log
            WHERE application_id = $1
              AND (payload->>'description' ILIKE $2 OR payload->>'reference' ILIKE $2)
            ORDER BY committed_at DESC
            LIMIT $3 OFFSET $4
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
            0,
            Decimal::ZERO,
            Decimal::ZERO,
            Decimal::ZERO,
        ))
    }

    async fn get_account_summary(
        &self,
        tenant_id: Uuid,
        _as_of: Option<DateTime<Utc>>,
    ) -> Result<AccountSummary, LedgerQueryError> {
        let _sql = r#"
            SELECT account_type, COUNT(*) as account_count, SUM(current_balance) as balance
            FROM core.account_registry
            WHERE primary_application_id = $1
            GROUP BY account_type
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(AccountSummary {
            tenant_id,
            total_accounts: 0,
            balances: Vec::new(),
            total_liabilities: Decimal::ZERO,
            total_assets: Decimal::ZERO,
            as_of: Utc::now(),
        })
    }

    async fn get_movement_legs(
        &self,
        _transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<MovementLeg>, LedgerQueryError> {
        let _sql = r#"
            SELECT leg_id, leg_sequence, account_id, direction,
                   amount, currency, coa_code, description, posted_at
            FROM core.movement_legs
            WHERE transaction_id = $1 AND tenant_id = $2
            ORDER BY leg_sequence ASC
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    async fn verify_double_entry(
        &self,
        _transaction_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<(bool, Decimal, Decimal, Decimal), LedgerQueryError> {
        let _sql = r#"
            SELECT direction, amount
            FROM core.movement_legs
            WHERE transaction_id = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((true, Decimal::ZERO, Decimal::ZERO, Decimal::ZERO))
    }

    // VirtualAccountService
    async fn get_virtual_account(
        &self,
        virtual_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<VirtualAccount, LedgerQueryError> {
        let _sql = r#"
            SELECT virtual_account_id, parent_account_id, virtual_account_name,
                   virtual_account_number, virtual_account_type, status,
                   current_balance, available_balance, held_amount, currency,
                   target_amount, target_date, progress_percentage, auto_sweep_enabled,
                   opened_at, closed_at, matured_at
            FROM core.virtual_accounts
            WHERE virtual_account_id = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::VirtualAccountNotFound(
            virtual_account_id.to_string(),
        ))
    }

    async fn list_virtual_accounts(
        &self,
        tenant_id: Uuid,
        _parent_account_id: Option<Uuid>,
        _types: Vec<VirtualAccountType>,
        _statuses: Vec<VirtualAccountStatus>,
        _pagination: Pagination,
    ) -> Result<(Vec<VirtualAccount>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT virtual_account_id, parent_account_id, virtual_account_name,
                   virtual_account_number, virtual_account_type, status,
                   current_balance, available_balance, held_amount, currency,
                   target_amount, target_date, progress_percentage, auto_sweep_enabled,
                   opened_at, closed_at, matured_at
            FROM core.virtual_accounts
            WHERE tenant_id = $1
            ORDER BY opened_at DESC
            LIMIT $2 OFFSET $3
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    async fn get_virtual_account_summary(
        &self,
        _parent_account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<VirtualAccountCurrencySummary>, LedgerQueryError> {
        let _sql = r#"
            SELECT currency,
                   SUM(current_balance) as total_balance,
                   SUM(available_balance) as total_available,
                   SUM(held_amount) as total_held,
                   COUNT(*) as account_count
            FROM core.virtual_accounts
            WHERE parent_account_id = $1 AND tenant_id = $2
            GROUP BY currency
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    // LiquidityPositionService
    async fn get_liquidity_position(
        &self,
        position_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<LiquidityPosition, LedgerQueryError> {
        let _sql = r#"
            SELECT position_id, position_reference, account_id, tenant_id,
                   position_type, amount, currency, status, purpose_code,
                   description, created_at, effective_date, expires_at,
                   released_at, auto_release, release_reason
            FROM core.liquidity_positions
            WHERE position_id = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::LiquidityPositionNotFound(
            position_id.to_string(),
        ))
    }

    async fn list_liquidity_positions(
        &self,
        tenant_id: Uuid,
        _account_id: Option<Uuid>,
        _types: Vec<LiquidityPositionType>,
        _statuses: Vec<LiquidityPositionStatus>,
        _pagination: Pagination,
    ) -> Result<(Vec<LiquidityPosition>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT position_id, position_reference, account_id, tenant_id,
                   position_type, amount, currency, status, purpose_code,
                   description, created_at, effective_date, expires_at,
                   released_at, auto_release, release_reason
            FROM core.liquidity_positions
            WHERE tenant_id = $1
            ORDER BY created_at DESC
            LIMIT $2 OFFSET $3
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    async fn get_liquidity_summary(
        &self,
        _account_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<LiquiditySummaryItem>, LedgerQueryError> {
        let _sql = r#"
            SELECT position_type, currency,
                   SUM(amount) as total_amount, COUNT(*) as position_count
            FROM core.liquidity_positions
            WHERE account_id = $1 AND tenant_id = $2
            GROUP BY position_type, currency
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    async fn get_expiring_positions(
        &self,
        tenant_id: Uuid,
        _lookahead_minutes: i32,
    ) -> Result<Vec<ExpiringPosition>, LedgerQueryError> {
        let _sql = r#"
            SELECT position_id, account_id, position_type, amount, currency, expires_at
            FROM core.liquidity_positions
            WHERE tenant_id = $1
              AND status = 'ACTIVE'
              AND expires_at BETWEEN NOW() AND NOW() + INTERVAL '$2 minutes'
            ORDER BY expires_at ASC
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    // SettlementService
    async fn get_settlement_instruction(
        &self,
        settlement_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SettlementInstruction, LedgerQueryError> {
        let _sql = r#"
            SELECT settlement_id, settlement_reference, tenant_id,
                   counterparty_id, counterparty_name, settlement_type,
                   direction, amount, currency, status, scheduled_at,
                   settlement_date, executed_at, completed_at,
                   settlement_account, counterparty_account, transaction_count,
                   gross_amount, net_amount, fees_amount,
                   confirmation_reference, failure_reason, retry_count
            FROM core.settlement_instructions
            WHERE settlement_id = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::SettlementNotFound(
            settlement_id.to_string(),
        ))
    }

    async fn list_settlement_instructions(
        &self,
        tenant_id: Uuid,
        _settlement_type: Option<SettlementType>,
        _statuses: Vec<SettlementStatus>,
        _from: DateTime<Utc>,
        _to: DateTime<Utc>,
        _pagination: Pagination,
    ) -> Result<(Vec<SettlementInstruction>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT settlement_id, settlement_reference, tenant_id,
                   counterparty_id, counterparty_name, settlement_type,
                   direction, amount, currency, status, scheduled_at,
                   settlement_date, executed_at, completed_at,
                   settlement_account, counterparty_account, transaction_count,
                   gross_amount, net_amount, fees_amount,
                   confirmation_reference, failure_reason, retry_count
            FROM core.settlement_instructions
            WHERE tenant_id = $1
              AND scheduled_at >= $2 AND scheduled_at <= $3
            ORDER BY scheduled_at DESC
            LIMIT $4 OFFSET $5
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    async fn get_pending_settlements(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SettlementInstruction>, LedgerQueryError> {
        let _sql = r#"
            SELECT settlement_id, settlement_reference, tenant_id,
                   counterparty_id, counterparty_name, settlement_type,
                   direction, amount, currency, status, scheduled_at,
                   settlement_date, executed_at, completed_at,
                   settlement_account, counterparty_account, transaction_count,
                   gross_amount, net_amount, fees_amount,
                   confirmation_reference, failure_reason, retry_count
            FROM core.settlement_instructions
            WHERE tenant_id = $1
              AND status IN ('PENDING', 'READY', 'EXECUTING')
            ORDER BY scheduled_at ASC
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    async fn get_settlement_summary(
        &self,
        tenant_id: Uuid,
        _start_date: DateTime<Utc>,
        _end_date: DateTime<Utc>,
    ) -> Result<Vec<SettlementSummaryItem>, LedgerQueryError> {
        let _sql = r#"
            SELECT settlement_type, direction, currency,
                   SUM(amount) as total_amount,
                   COUNT(*) as count,
                   SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) as completed_count,
                   SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed_count
            FROM core.settlement_instructions
            WHERE tenant_id = $1
              AND settlement_date >= $2 AND settlement_date <= $3
            GROUP BY settlement_type, direction, currency
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    // SuspenseService
    async fn get_suspense_item(
        &self,
        suspense_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<SuspenseItem, LedgerQueryError> {
        let _sql = r#"
            SELECT suspense_id, suspense_reference, source_transaction_id,
                   amount, currency, category, priority, status,
                   description, days_in_suspense, escalation_level,
                   resolution_type, resolution_date, resolution_notes, created_at
            FROM core.suspense_items
            WHERE suspense_id = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::SuspenseItemNotFound(
            suspense_id.to_string(),
        ))
    }

    async fn list_suspense_items(
        &self,
        tenant_id: Uuid,
        _statuses: Vec<SuspenseStatus>,
        _categories: Vec<SuspenseCategory>,
        _priority: Option<&str>,
        _pagination: Pagination,
    ) -> Result<(Vec<SuspenseItem>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT suspense_id, suspense_reference, source_transaction_id,
                   amount, currency, category, priority, status,
                   description, days_in_suspense, escalation_level,
                   resolution_type, resolution_date, resolution_notes, created_at
            FROM core.suspense_items
            WHERE tenant_id = $1
            ORDER BY created_at DESC
            LIMIT $2 OFFSET $3
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    async fn get_suspense_aging_report(
        &self,
        tenant_id: Uuid,
    ) -> Result<Vec<SuspenseAgingBucket>, LedgerQueryError> {
        let _sql = r#"
            SELECT category,
                   CASE
                       WHEN days_in_suspense BETWEEN 0 AND 30 THEN 0
                       WHEN days_in_suspense BETWEEN 31 AND 60 THEN 31
                       WHEN days_in_suspense BETWEEN 61 AND 90 THEN 61
                       ELSE 91
                   END as days_range_start,
                   CASE
                       WHEN days_in_suspense BETWEEN 0 AND 30 THEN 30
                       WHEN days_in_suspense BETWEEN 31 AND 60 THEN 60
                       WHEN days_in_suspense BETWEEN 61 AND 90 THEN 90
                       ELSE 999
                   END as days_range_end,
                   COUNT(*) as count,
                   SUM(amount) as total_amount
            FROM core.suspense_items
            WHERE tenant_id = $1 AND status != 'RESOLVED'
            GROUP BY category, days_range_start, days_range_end
        "#;
        self.set_tenant(tenant_id).await?;
        Ok(Vec::new())
    }

    async fn get_suspense_activity_log(
        &self,
        _suspense_id: Uuid,
        tenant_id: Uuid,
        _pagination: Pagination,
    ) -> Result<(Vec<SuspenseActivityEntry>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT activity_id, suspense_id, activity_type,
                   from_status, to_status, performed_by, notes, created_at
            FROM core.suspense_activity_log
            WHERE suspense_id = $1 AND tenant_id = $2
            ORDER BY created_at DESC
            LIMIT $3 OFFSET $4
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    // ChartOfAccountsService
    async fn get_coa_entry(
        &self,
        coa_code: &str,
        tenant_id: Uuid,
    ) -> Result<COAEntry, LedgerQueryError> {
        let _sql = r#"
            SELECT coa_code, tenant_id, account_name, account_category,
                   parent_code, level, is_leaf, normal_balance, is_active
            FROM core.chart_of_accounts
            WHERE coa_code = $1 AND tenant_id = $2
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::CoaEntryNotFound(coa_code.to_string()))
    }

    async fn list_coa_entries(
        &self,
        tenant_id: Uuid,
        _parent_code: Option<&str>,
        _account_category: Option<&str>,
        _pagination: Pagination,
    ) -> Result<(Vec<COAEntry>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT coa_code, tenant_id, account_name, account_category,
                   parent_code, level, is_leaf, normal_balance, is_active
            FROM core.chart_of_accounts
            WHERE tenant_id = $1
            ORDER BY coa_code ASC
            LIMIT $2 OFFSET $3
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }

    async fn get_period_end_balance(
        &self,
        account_id: Uuid,
        tenant_id: Uuid,
        fiscal_period_id: &str,
    ) -> Result<PeriodEndBalance, LedgerQueryError> {
        let _sql = r#"
            SELECT balance_id, account_id, tenant_id, fiscal_period_id,
                   opening_balance, closing_balance, total_debits, total_credits,
                   currency, is_adjusted, created_at
            FROM core.period_end_balances
            WHERE account_id = $1 AND tenant_id = $2 AND fiscal_period_id = $3
        "#;
        self.set_tenant(tenant_id).await?;
        Err(LedgerQueryError::PeriodEndBalanceNotFound(format!(
            "account:{} period:{}",
            account_id, fiscal_period_id
        )))
    }

    async fn list_period_end_balances(
        &self,
        tenant_id: Uuid,
        _fiscal_period_id: &str,
        _pagination: Pagination,
    ) -> Result<(Vec<PeriodEndBalance>, PaginationMetadata), LedgerQueryError> {
        let _sql = r#"
            SELECT balance_id, account_id, tenant_id, fiscal_period_id,
                   opening_balance, closing_balance, total_debits, total_credits,
                   currency, is_adjusted, created_at
            FROM core.period_end_balances
            WHERE tenant_id = $1 AND fiscal_period_id = $2
            ORDER BY account_id ASC
            LIMIT $3 OFFSET $4
        "#;
        self.set_tenant(tenant_id).await?;
        Ok((
            Vec::new(),
            PaginationMetadata {
                total_count: 0,
                next_page_token: String::new(),
                previous_page_token: String::new(),
                has_more: false,
            },
        ))
    }
}
