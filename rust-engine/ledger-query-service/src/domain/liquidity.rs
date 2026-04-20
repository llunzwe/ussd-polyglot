use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct LiquidityPosition {
    pub position_id: Uuid,
    pub position_reference: String,
    pub account_id: Uuid,
    pub tenant_id: Uuid,
    pub position_type: LiquidityPositionType,
    pub amount: Decimal,
    pub currency: String,
    pub status: LiquidityPositionStatus,
    pub purpose_code: String,
    pub description: String,
    pub created_at: DateTime<Utc>,
    pub effective_date: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub released_at: Option<DateTime<Utc>>,
    pub auto_release: bool,
    pub release_reason: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LiquidityPositionType {
    Unspecified,
    Held,
    Reserved,
    Collateral,
    Float,
    Pledged,
}

impl LiquidityPositionType {
    pub fn as_i32(&self) -> i32 {
        match self {
            LiquidityPositionType::Unspecified => 0,
            LiquidityPositionType::Held => 1,
            LiquidityPositionType::Reserved => 2,
            LiquidityPositionType::Collateral => 3,
            LiquidityPositionType::Float => 4,
            LiquidityPositionType::Pledged => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(LiquidityPositionType::Unspecified),
            1 => Some(LiquidityPositionType::Held),
            2 => Some(LiquidityPositionType::Reserved),
            3 => Some(LiquidityPositionType::Collateral),
            4 => Some(LiquidityPositionType::Float),
            5 => Some(LiquidityPositionType::Pledged),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum LiquidityPositionStatus {
    Unspecified,
    Active,
    Released,
    Expired,
    Confiscated,
    Pending,
}

impl LiquidityPositionStatus {
    pub fn as_i32(&self) -> i32 {
        match self {
            LiquidityPositionStatus::Unspecified => 0,
            LiquidityPositionStatus::Active => 1,
            LiquidityPositionStatus::Released => 2,
            LiquidityPositionStatus::Expired => 3,
            LiquidityPositionStatus::Confiscated => 4,
            LiquidityPositionStatus::Pending => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(LiquidityPositionStatus::Unspecified),
            1 => Some(LiquidityPositionStatus::Active),
            2 => Some(LiquidityPositionStatus::Released),
            3 => Some(LiquidityPositionStatus::Expired),
            4 => Some(LiquidityPositionStatus::Confiscated),
            5 => Some(LiquidityPositionStatus::Pending),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LiquiditySummaryItem {
    pub position_type: LiquidityPositionType,
    pub currency: String,
    pub total_amount: Decimal,
    pub position_count: i32,
}

#[derive(Debug, Clone)]
pub struct ExpiringPosition {
    pub position_id: Uuid,
    pub account_id: Uuid,
    pub position_type: LiquidityPositionType,
    pub amount: Decimal,
    pub currency: String,
    pub expires_at: DateTime<Utc>,
    pub minutes_until_expiry: f64,
}
