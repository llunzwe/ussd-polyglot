use chrono::{DateTime, Utc};
use rust_decimal::Decimal;

#[derive(Debug, Clone)]
pub struct InternalTransaction {
    pub transaction_id: String,
    pub reference: String,
    pub amount: Decimal,
    pub currency: String,
    pub status: String,
    pub timestamp: DateTime<Utc>,
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone)]
pub struct ExternalTransaction {
    pub external_id: String,
    pub reference: String,
    pub amount: Decimal,
    pub currency: String,
    pub status: String,
    pub timestamp: DateTime<Utc>,
    pub metadata: Option<serde_json::Value>,
}
