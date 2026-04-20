use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::discrepancy::{DiscrepancyType, ResolutionAction, ReconciliationStatus};
use crate::domain::error::ReconciliationError;
use crate::domain::matching_rule::MatchingRule;
use crate::domain::reconciliation_item::ReconciliationItem;
use crate::domain::reconciliation_run::ReconciliationRun;

#[async_trait]
pub trait ReconciliationStorePort: Send + Sync {
    async fn save_run(&self, run: &ReconciliationRun) -> Result<(), ReconciliationError>;
    async fn get_run(&self, run_id: Uuid, tenant_id: Uuid) -> Result<ReconciliationRun, ReconciliationError>;
    async fn list_runs(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
        statuses: Vec<ReconciliationStatus>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<ReconciliationRun>, ReconciliationError>;
    async fn save_item(&self, item: &ReconciliationItem) -> Result<(), ReconciliationError>;
    async fn get_items(
        &self,
        run_id: Uuid,
        tenant_id: Uuid,
        discrepancy_types: Vec<DiscrepancyType>,
        unresolved_only: bool,
    ) -> Result<Vec<ReconciliationItem>, ReconciliationError>;
    async fn get_item(&self, item_id: Uuid, tenant_id: Uuid) -> Result<ReconciliationItem, ReconciliationError>;
    async fn update_item_resolution(
        &self,
        item_id: Uuid,
        action: ResolutionAction,
        notes: &str,
        resolved_by: &str,
    ) -> Result<(), ReconciliationError>;
    async fn get_matching_rule(&self, rule_id: Uuid, tenant_id: Uuid) -> Result<MatchingRule, ReconciliationError>;
    async fn list_matching_rules(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
    ) -> Result<Vec<MatchingRule>, ReconciliationError>;
}
