use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::discrepancy::{DiscrepancyType, ResolutionAction};

#[derive(Debug, Clone)]
pub struct ReconciliationItem {
    pub item_id: Uuid,
    pub run_id: Uuid,
    pub transaction_id: String,
    pub discrepancy_type: DiscrepancyType,
    pub internal_status: String,
    pub external_status: String,
    pub internal_amount: Decimal,
    pub external_amount: Decimal,
    pub difference: Decimal,
    pub resolved: bool,
    pub resolution_action: Option<ResolutionAction>,
    pub resolved_by: Option<String>,
    pub resolved_at: Option<DateTime<Utc>>,
    pub notes: Option<String>,
}
