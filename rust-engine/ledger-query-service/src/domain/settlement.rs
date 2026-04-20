use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct SettlementInstruction {
    pub settlement_id: Uuid,
    pub settlement_reference: String,
    pub tenant_id: Uuid,
    pub counterparty_id: String,
    pub counterparty_name: String,
    pub settlement_type: SettlementType,
    pub direction: String,
    pub amount: Decimal,
    pub currency: String,
    pub status: SettlementStatus,
    pub scheduled_at: Option<DateTime<Utc>>,
    pub settlement_date: Option<DateTime<Utc>>,
    pub executed_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub settlement_account: String,
    pub counterparty_account: String,
    pub transaction_count: i32,
    pub gross_amount: Decimal,
    pub net_amount: Decimal,
    pub fees_amount: Decimal,
    pub confirmation_reference: String,
    pub failure_reason: String,
    pub retry_count: i32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SettlementType {
    Unspecified,
    Rtgs,
    Net,
    Batch,
    Immediate,
    MobileMoney,
}

impl SettlementType {
    pub fn as_i32(&self) -> i32 {
        match self {
            SettlementType::Unspecified => 0,
            SettlementType::Rtgs => 1,
            SettlementType::Net => 2,
            SettlementType::Batch => 3,
            SettlementType::Immediate => 4,
            SettlementType::MobileMoney => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(SettlementType::Unspecified),
            1 => Some(SettlementType::Rtgs),
            2 => Some(SettlementType::Net),
            3 => Some(SettlementType::Batch),
            4 => Some(SettlementType::Immediate),
            5 => Some(SettlementType::MobileMoney),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SettlementStatus {
    Unspecified,
    Pending,
    Ready,
    Executing,
    Completed,
    Failed,
    Cancelled,
}

impl SettlementStatus {
    pub fn as_i32(&self) -> i32 {
        match self {
            SettlementStatus::Unspecified => 0,
            SettlementStatus::Pending => 1,
            SettlementStatus::Ready => 2,
            SettlementStatus::Executing => 3,
            SettlementStatus::Completed => 4,
            SettlementStatus::Failed => 5,
            SettlementStatus::Cancelled => 6,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(SettlementStatus::Unspecified),
            1 => Some(SettlementStatus::Pending),
            2 => Some(SettlementStatus::Ready),
            3 => Some(SettlementStatus::Executing),
            4 => Some(SettlementStatus::Completed),
            5 => Some(SettlementStatus::Failed),
            6 => Some(SettlementStatus::Cancelled),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SettlementSummaryItem {
    pub settlement_type: SettlementType,
    pub direction: String,
    pub currency: String,
    pub total_amount: Decimal,
    pub count: i64,
    pub completed_count: i64,
    pub failed_count: i64,
}
