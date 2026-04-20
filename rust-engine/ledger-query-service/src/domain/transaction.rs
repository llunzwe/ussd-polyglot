use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::collections::HashMap;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Transaction {
    pub transaction_id: Uuid,
    pub transaction_uuid: String,
    pub tenant_id: Uuid,
    pub account_id: Uuid,
    pub transaction_type: TransactionType,
    pub amount: Decimal,
    pub balance_after: Decimal,
    pub description: String,
    pub reference: String,
    pub posted_at: DateTime<Utc>,
    pub effective_at: DateTime<Utc>,
    pub session_id: String,
    pub payment_id: String,
    pub metadata: HashMap<String, String>,
    pub version: i64,
    pub correlation_id: String,
    pub idempotency_key: String,
    pub status: String,
    pub record_hash: String,
    pub previous_hash: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TransactionType {
    Unspecified,
    Credit,
    Debit,
    Hold,
    Release,
    Adjustment,
    Reversal,
    Fee,
    Settlement,
    Interest,
}

impl TransactionType {
    pub fn as_i32(&self) -> i32 {
        match self {
            TransactionType::Unspecified => 0,
            TransactionType::Credit => 1,
            TransactionType::Debit => 2,
            TransactionType::Hold => 3,
            TransactionType::Release => 4,
            TransactionType::Adjustment => 5,
            TransactionType::Reversal => 6,
            TransactionType::Fee => 7,
            TransactionType::Settlement => 8,
            TransactionType::Interest => 9,
        }
    }

    pub fn from_i32(v: i32) -> Option<Self> {
        match v {
            0 => Some(TransactionType::Unspecified),
            1 => Some(TransactionType::Credit),
            2 => Some(TransactionType::Debit),
            3 => Some(TransactionType::Hold),
            4 => Some(TransactionType::Release),
            5 => Some(TransactionType::Adjustment),
            6 => Some(TransactionType::Reversal),
            7 => Some(TransactionType::Fee),
            8 => Some(TransactionType::Settlement),
            9 => Some(TransactionType::Interest),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct MovementLeg {
    pub leg_id: String,
    pub leg_sequence: i32,
    pub account_id: String,
    pub direction: String,
    pub amount: Decimal,
    pub currency: String,
    pub coa_code: String,
    pub description: String,
    pub posted_at: DateTime<Utc>,
}
