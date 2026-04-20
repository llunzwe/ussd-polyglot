use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::discrepancy::ReconciliationStatus;

#[derive(Debug, Clone)]
pub struct ReconciliationRun {
    pub run_id: Uuid,
    pub tenant_id: Uuid,
    pub provider_name: String,
    pub status: ReconciliationStatus,
    pub period_start: DateTime<Utc>,
    pub period_end: DateTime<Utc>,
    pub total_records: i32,
    pub matched_count: i32,
    pub discrepancy_count: i32,
    pub resolved_count: i32,
    pub internal_total: Decimal,
    pub external_total: Decimal,
    pub discrepancy_amount: Decimal,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub initiated_by: String,
    pub approved_by: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
}

impl ReconciliationRun {
    pub fn new(
        run_id: Uuid,
        tenant_id: Uuid,
        provider_name: String,
        period_start: DateTime<Utc>,
        period_end: DateTime<Utc>,
        initiated_by: String,
    ) -> Self {
        Self {
            run_id,
            tenant_id,
            provider_name,
            status: ReconciliationStatus::Pending,
            period_start,
            period_end,
            total_records: 0,
            matched_count: 0,
            discrepancy_count: 0,
            resolved_count: 0,
            internal_total: Decimal::ZERO,
            external_total: Decimal::ZERO,
            discrepancy_amount: Decimal::ZERO,
            started_at: None,
            completed_at: None,
            initiated_by,
            approved_by: None,
            approved_at: None,
        }
    }
}
