use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct MatchingRule {
    pub rule_id: Uuid,
    pub tenant_id: Uuid,
    pub provider_name: String,
    pub rule_name: String,
    pub match_fields: Vec<String>,
    pub tolerance_amount: Decimal,
    pub tolerance_time_seconds: i32,
    pub auto_resolve: bool,
    pub is_active: bool,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
}
