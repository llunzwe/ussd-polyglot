use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct SuspenseItem {
    pub suspense_id: Uuid,
    pub suspense_reference: String,
    pub source_transaction_id: String,
    pub amount: Decimal,
    pub currency: String,
    pub category: SuspenseCategory,
    pub priority: String,
    pub status: SuspenseStatus,
    pub description: String,
    pub days_in_suspense: i32,
    pub escalation_level: i32,
    pub resolution_type: Option<SuspenseResolutionType>,
    pub resolution_date: Option<DateTime<Utc>>,
    pub resolution_notes: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SuspenseCategory {
    Unspecified,
    Unidentified,
    PendingDocs,
    Disputed,
    Investigation,
    AwaitingApproval,
}

impl SuspenseCategory {
    pub fn as_i32(&self) -> i32 {
        match self {
            SuspenseCategory::Unspecified => 0,
            SuspenseCategory::Unidentified => 1,
            SuspenseCategory::PendingDocs => 2,
            SuspenseCategory::Disputed => 3,
            SuspenseCategory::Investigation => 4,
            SuspenseCategory::AwaitingApproval => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(SuspenseCategory::Unspecified),
            1 => Some(SuspenseCategory::Unidentified),
            2 => Some(SuspenseCategory::PendingDocs),
            3 => Some(SuspenseCategory::Disputed),
            4 => Some(SuspenseCategory::Investigation),
            5 => Some(SuspenseCategory::AwaitingApproval),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SuspenseStatus {
    Unspecified,
    Open,
    UnderReview,
    PendingApproval,
    Resolved,
    WrittenOff,
}

impl SuspenseStatus {
    pub fn as_i32(&self) -> i32 {
        match self {
            SuspenseStatus::Unspecified => 0,
            SuspenseStatus::Open => 1,
            SuspenseStatus::UnderReview => 2,
            SuspenseStatus::PendingApproval => 3,
            SuspenseStatus::Resolved => 4,
            SuspenseStatus::WrittenOff => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(SuspenseStatus::Unspecified),
            1 => Some(SuspenseStatus::Open),
            2 => Some(SuspenseStatus::UnderReview),
            3 => Some(SuspenseStatus::PendingApproval),
            4 => Some(SuspenseStatus::Resolved),
            5 => Some(SuspenseStatus::WrittenOff),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SuspenseResolutionType {
    Unspecified,
    Transfer,
    Return,
    WriteOff,
    Reclassify,
    Adjust,
}

impl SuspenseResolutionType {
    pub fn as_i32(&self) -> i32 {
        match self {
            SuspenseResolutionType::Unspecified => 0,
            SuspenseResolutionType::Transfer => 1,
            SuspenseResolutionType::Return => 2,
            SuspenseResolutionType::WriteOff => 3,
            SuspenseResolutionType::Reclassify => 4,
            SuspenseResolutionType::Adjust => 5,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(SuspenseResolutionType::Unspecified),
            1 => Some(SuspenseResolutionType::Transfer),
            2 => Some(SuspenseResolutionType::Return),
            3 => Some(SuspenseResolutionType::WriteOff),
            4 => Some(SuspenseResolutionType::Reclassify),
            5 => Some(SuspenseResolutionType::Adjust),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct SuspenseAgingBucket {
    pub category: String,
    pub days_range_start: i32,
    pub days_range_end: i32,
    pub count: i64,
    pub total_amount: Decimal,
}

#[derive(Debug, Clone)]
pub struct SuspenseActivityEntry {
    pub activity_id: String,
    pub suspense_id: String,
    pub activity_type: String,
    pub from_status: String,
    pub to_status: String,
    pub performed_by: String,
    pub notes: String,
    pub created_at: DateTime<Utc>,
}
