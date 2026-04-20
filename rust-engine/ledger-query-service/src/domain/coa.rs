use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct COAEntry {
    pub coa_code: String,
    pub tenant_id: Uuid,
    pub account_name: String,
    pub account_category: String,
    pub parent_code: String,
    pub level: i32,
    pub is_leaf: bool,
    pub normal_balance: String,
    pub is_active: bool,
}

#[derive(Debug, Clone)]
pub struct PeriodEndBalance {
    pub balance_id: String,
    pub account_id: Uuid,
    pub tenant_id: Uuid,
    pub fiscal_period_id: String,
    pub opening_balance: Decimal,
    pub closing_balance: Decimal,
    pub total_debits: Decimal,
    pub total_credits: Decimal,
    pub currency: String,
    pub is_adjusted: bool,
    pub created_at: DateTime<Utc>,
}
