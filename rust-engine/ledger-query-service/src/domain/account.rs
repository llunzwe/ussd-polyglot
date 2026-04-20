use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct AccountBalance {
    pub account_id: Uuid,
    pub tenant_id: Uuid,
    pub account_type: AccountType,
    pub current_balance: Decimal,
    pub available_balance: Decimal,
    pub hold_balance: Decimal,
    pub currency_code: String,
    pub as_of: DateTime<Utc>,
    pub version: i64,
}

#[derive(Debug, Clone)]
pub struct AccountSummary {
    pub tenant_id: Uuid,
    pub total_accounts: i32,
    pub balances: Vec<BalanceByType>,
    pub total_liabilities: Decimal,
    pub total_assets: Decimal,
    pub as_of: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct BalanceByType {
    pub account_type: AccountType,
    pub balance: Decimal,
    pub account_count: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AccountType {
    Unspecified,
    Customer,
    Float,
    Commission,
    Escrow,
    Suspense,
    Merchant,
    Aggregator,
    Provider,
}

impl AccountType {
    pub fn as_i32(&self) -> i32 {
        match self {
            AccountType::Unspecified => 0,
            AccountType::Customer => 1,
            AccountType::Float => 2,
            AccountType::Commission => 3,
            AccountType::Escrow => 4,
            AccountType::Suspense => 5,
            AccountType::Merchant => 6,
            AccountType::Aggregator => 7,
            AccountType::Provider => 8,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(AccountType::Unspecified),
            1 => Some(AccountType::Customer),
            2 => Some(AccountType::Float),
            3 => Some(AccountType::Commission),
            4 => Some(AccountType::Escrow),
            5 => Some(AccountType::Suspense),
            6 => Some(AccountType::Merchant),
            7 => Some(AccountType::Aggregator),
            8 => Some(AccountType::Provider),
            _ => None,
        }
    }
}
