use std::sync::Arc;

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use tracing::{info, warn};
use uuid::Uuid;

use crate::domain::discrepancy::{DiscrepancyType, ResolutionAction, ReconciliationStatus};
use crate::domain::error::ReconciliationError;
use crate::domain::matching_rule::MatchingRule;
use crate::domain::reconciliation_item::ReconciliationItem;
use crate::domain::reconciliation_run::ReconciliationRun;
use crate::domain::transaction::{ExternalTransaction, InternalTransaction};
use crate::ports::external_statement::ExternalStatementPort;
use crate::ports::recon_store::ReconciliationStorePort;
use crate::ports::transaction_source::TransactionSourcePort;

#[derive(Clone)]
pub struct ReconciliationHandler {
    pub transaction_source: Arc<dyn TransactionSourcePort>,
    pub external_statement: Arc<dyn ExternalStatementPort>,
    pub store: Arc<dyn ReconciliationStorePort>,
}

impl std::fmt::Debug for ReconciliationHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReconciliationHandler")
            .field("transaction_source", &"<dyn TransactionSourcePort>")
            .field("external_statement", &"<dyn ExternalStatementPort>")
            .field("store", &"<dyn ReconciliationStorePort>")
            .finish()
    }
}

impl ReconciliationHandler {
    pub fn new(
        transaction_source: Arc<dyn TransactionSourcePort>,
        external_statement: Arc<dyn ExternalStatementPort>,
        store: Arc<dyn ReconciliationStorePort>,
    ) -> Self {
        Self {
            transaction_source,
            external_statement,
            store,
        }
    }

    pub async fn start_reconciliation(
        &self,
        tenant_id: Uuid,
        provider_name: &str,
        period_start: DateTime<Utc>,
        period_end: DateTime<Utc>,
        initiated_by: &str,
        tolerance: Decimal,
    ) -> Result<ReconciliationRun, ReconciliationError> {
        info!(%tenant_id, provider = %provider_name, "Starting reconciliation");

        let run_id = Uuid::new_v4();
        let mut run = ReconciliationRun::new(
            run_id,
            tenant_id,
            provider_name.to_string(),
            period_start,
            period_end,
            initiated_by.to_string(),
        );
        run.status = ReconciliationStatus::Running;
        run.started_at = Some(Utc::now());

        self.store.save_run(&run).await?;

        let internal_txns = self
            .transaction_source
            .fetch_internal_transactions(tenant_id, provider_name, period_start, period_end)
            .await;

        let external_txns = self
            .external_statement
            .fetch_external_transactions(provider_name, period_start, period_end)
            .await;

        let (internal_txns, external_txns) = match (internal_txns, external_txns) {
            (Ok(i), Ok(e)) => (i, e),
            (Err(e), _) | (_, Err(e)) => {
                run.status = ReconciliationStatus::Failed;
                run.completed_at = Some(Utc::now());
                self.store.save_run(&run).await?;
                return Err(e);
            }
        };

        run.internal_total = internal_txns.iter().map(|t| t.amount).sum();
        run.external_total = external_txns.iter().map(|t| t.amount).sum();

        let items = self.match_transactions(run_id, &internal_txns, &external_txns, tolerance);

        run.total_records = (internal_txns.len() + external_txns.len()) as i32;
        run.matched_count = items.iter().filter(|i| i.resolved).count() as i32;
        run.discrepancy_count = items.iter().filter(|i| !i.resolved).count() as i32;
        run.discrepancy_amount = items.iter().map(|i| i.difference.abs()).sum();

        for item in &items {
            self.store.save_item(item).await?;
        }

        run.status = if run.discrepancy_count > 0 {
            ReconciliationStatus::PartiallyResolved
        } else {
            ReconciliationStatus::Completed
        };
        run.completed_at = Some(Utc::now());
        self.store.save_run(&run).await?;

        info!(%run_id, "Reconciliation completed");
        Ok(run)
    }

    pub async fn get_reconciliation_run(
        &self,
        run_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<ReconciliationRun, ReconciliationError> {
        self.store.get_run(run_id, tenant_id).await
    }

    pub async fn list_reconciliation_runs(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
        statuses: Vec<ReconciliationStatus>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<ReconciliationRun>, ReconciliationError> {
        self.store.list_runs(tenant_id, provider_name, statuses, from, to).await
    }

    pub async fn get_reconciliation_items(
        &self,
        run_id: Uuid,
        tenant_id: Uuid,
        discrepancy_types: Vec<DiscrepancyType>,
        unresolved_only: bool,
    ) -> Result<Vec<ReconciliationItem>, ReconciliationError> {
        self.store
            .get_items(run_id, tenant_id, discrepancy_types, unresolved_only)
            .await
    }

    pub async fn resolve_discrepancy(
        &self,
        item_id: Uuid,
        _run_id: Uuid,
        tenant_id: Uuid,
        action: ResolutionAction,
        notes: &str,
        resolved_by: &str,
    ) -> Result<ReconciliationItem, ReconciliationError> {
        info!(%item_id, action = %action, "Resolving discrepancy");
        self.store
            .update_item_resolution(item_id, action, notes, resolved_by)
            .await?;
        self.store.get_item(item_id, tenant_id).await
    }

    pub async fn bulk_resolve_discrepancies(
        &self,
        _run_id: Uuid,
        _tenant_id: Uuid,
        item_ids: Vec<Uuid>,
        action: ResolutionAction,
        notes: &str,
        resolved_by: &str,
    ) -> Result<i32, ReconciliationError> {
        let mut count = 0i32;
        for item_id in item_ids {
            match self
                .store
                .update_item_resolution(item_id, action.clone(), notes, resolved_by)
                .await
            {
                Ok(()) => count += 1,
                Err(e) => {
                    warn!(%item_id, error = %e, "Failed to resolve item");
                }
            }
        }
        Ok(count)
    }

    pub async fn generate_report(
        &self,
        run_id: Uuid,
        tenant_id: Uuid,
        format: &str,
    ) -> Result<(Uuid, String), ReconciliationError> {
        info!(%run_id, format = %format, "Generating report");
        let run = self.store.get_run(run_id, tenant_id).await?;
        let report_id = Uuid::new_v4();
        let download_url = format!(
            "/reports/{}/reconciliation-{}.{}?tenant={}",
            report_id,
            run.run_id,
            format.to_lowercase(),
            tenant_id
        );
        Ok((report_id, download_url))
    }

    pub async fn get_matching_rule(
        &self,
        rule_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<MatchingRule, ReconciliationError> {
        self.store.get_matching_rule(rule_id, tenant_id).await
    }

    pub async fn list_matching_rules(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
    ) -> Result<Vec<MatchingRule>, ReconciliationError> {
        self.store.list_matching_rules(tenant_id, provider_name).await
    }

    fn match_transactions(
        &self,
        run_id: Uuid,
        internal: &[InternalTransaction],
        external: &[ExternalTransaction],
        tolerance: Decimal,
    ) -> Vec<ReconciliationItem> {
        let mut items = Vec::new();
        let mut matched_external = vec![false; external.len()];

        for int_txn in internal {
            let mut found = false;
            for (idx, ext_txn) in external.iter().enumerate() {
                if matched_external[idx] {
                    continue;
                }
                if self.is_match(int_txn, ext_txn, tolerance) {
                    matched_external[idx] = true;
                    found = true;
                    let diff = (int_txn.amount - ext_txn.amount).abs();
                    if diff > Decimal::ZERO {
                        items.push(ReconciliationItem {
                            item_id: Uuid::new_v4(),
                            run_id,
                            transaction_id: int_txn.transaction_id.clone(),
                            discrepancy_type: DiscrepancyType::AmountMismatch,
                            internal_status: int_txn.status.clone(),
                            external_status: ext_txn.status.clone(),
                            internal_amount: int_txn.amount,
                            external_amount: ext_txn.amount,
                            difference: diff,
                            resolved: false,
                            resolution_action: None,
                            resolved_by: None,
                            resolved_at: None,
                            notes: None,
                        });
                    }
                    break;
                }
            }
            if !found {
                items.push(ReconciliationItem {
                    item_id: Uuid::new_v4(),
                    run_id,
                    transaction_id: int_txn.transaction_id.clone(),
                    discrepancy_type: DiscrepancyType::MissingExternal,
                    internal_status: int_txn.status.clone(),
                    external_status: String::new(),
                    internal_amount: int_txn.amount,
                    external_amount: Decimal::ZERO,
                    difference: int_txn.amount,
                    resolved: false,
                    resolution_action: None,
                    resolved_by: None,
                    resolved_at: None,
                    notes: None,
                });
            }
        }

        for (idx, ext_txn) in external.iter().enumerate() {
            if !matched_external[idx] {
                items.push(ReconciliationItem {
                    item_id: Uuid::new_v4(),
                    run_id,
                    transaction_id: ext_txn.external_id.clone(),
                    discrepancy_type: DiscrepancyType::MissingInternal,
                    internal_status: String::new(),
                    external_status: ext_txn.status.clone(),
                    internal_amount: Decimal::ZERO,
                    external_amount: ext_txn.amount,
                    difference: ext_txn.amount,
                    resolved: false,
                    resolution_action: None,
                    resolved_by: None,
                    resolved_at: None,
                    notes: None,
                });
            }
        }

        items
    }

    fn is_match(
        &self,
        internal: &InternalTransaction,
        external: &ExternalTransaction,
        tolerance: Decimal,
    ) -> bool {
        let ref_match = !internal.reference.is_empty()
            && !external.reference.is_empty()
            && internal.reference == external.reference;
        let amount_match = (internal.amount - external.amount).abs() <= tolerance;
        ref_match && amount_match
    }
}
