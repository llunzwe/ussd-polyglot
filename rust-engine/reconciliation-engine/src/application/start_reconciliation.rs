use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct StartReconciliationCommand {
    pub tenant_id: Uuid,
    pub provider_name: String,
    pub period_start: DateTime<Utc>,
    pub period_end: DateTime<Utc>,
    pub initiated_by: String,
    pub tolerance: Decimal,
}
