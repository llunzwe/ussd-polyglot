use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct VirtualAccount {
    pub virtual_account_id: Uuid,
    pub parent_account_id: Uuid,
    pub virtual_account_name: String,
    pub virtual_account_number: String,
    pub virtual_account_type: VirtualAccountType,
    pub status: VirtualAccountStatus,
    pub current_balance: Decimal,
    pub available_balance: Decimal,
    pub held_amount: Decimal,
    pub currency: String,
    pub target_amount: Decimal,
    pub target_date: Option<DateTime<Utc>>,
    pub progress_percentage: f64,
    pub auto_sweep_enabled: bool,
    pub opened_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
    pub matured_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum VirtualAccountType {
    Unspecified,
    Budget,
    SavingsGoal,
    Escrow,
    Reserve,
    TemporaryHold,
    EcocashWallet,
    TelecashWallet,
    OnemoneyWallet,
    MerchantSettlement,
}

impl VirtualAccountType {
    pub fn as_i32(&self) -> i32 {
        match self {
            VirtualAccountType::Unspecified => 0,
            VirtualAccountType::Budget => 1,
            VirtualAccountType::SavingsGoal => 2,
            VirtualAccountType::Escrow => 3,
            VirtualAccountType::Reserve => 4,
            VirtualAccountType::TemporaryHold => 5,
            VirtualAccountType::EcocashWallet => 6,
            VirtualAccountType::TelecashWallet => 7,
            VirtualAccountType::OnemoneyWallet => 8,
            VirtualAccountType::MerchantSettlement => 9,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(VirtualAccountType::Unspecified),
            1 => Some(VirtualAccountType::Budget),
            2 => Some(VirtualAccountType::SavingsGoal),
            3 => Some(VirtualAccountType::Escrow),
            4 => Some(VirtualAccountType::Reserve),
            5 => Some(VirtualAccountType::TemporaryHold),
            6 => Some(VirtualAccountType::EcocashWallet),
            7 => Some(VirtualAccountType::TelecashWallet),
            8 => Some(VirtualAccountType::OnemoneyWallet),
            9 => Some(VirtualAccountType::MerchantSettlement),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum VirtualAccountStatus {
    Unspecified,
    Active,
    Frozen,
    Closed,
    Matured,
}

impl VirtualAccountStatus {
    pub fn as_i32(&self) -> i32 {
        match self {
            VirtualAccountStatus::Unspecified => 0,
            VirtualAccountStatus::Active => 1,
            VirtualAccountStatus::Frozen => 2,
            VirtualAccountStatus::Closed => 3,
            VirtualAccountStatus::Matured => 4,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(VirtualAccountStatus::Unspecified),
            1 => Some(VirtualAccountStatus::Active),
            2 => Some(VirtualAccountStatus::Frozen),
            3 => Some(VirtualAccountStatus::Closed),
            4 => Some(VirtualAccountStatus::Matured),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct VirtualAccountCurrencySummary {
    pub currency: String,
    pub total_balance: Decimal,
    pub total_available: Decimal,
    pub total_held: Decimal,
    pub account_count: i32,
}
