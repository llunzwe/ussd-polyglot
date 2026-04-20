use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::{Pool, Postgres, Row};
use uuid::Uuid;

use crate::domain::discrepancy::{DiscrepancyType, ResolutionAction, ReconciliationStatus};
use crate::domain::error::ReconciliationError;
use crate::domain::matching_rule::MatchingRule;
use crate::domain::reconciliation_item::ReconciliationItem;
use crate::domain::reconciliation_run::ReconciliationRun;
use crate::ports::recon_store::ReconciliationStorePort;

#[derive(Debug, Clone)]
pub struct PostgresReconStore {
    pool: Pool<Postgres>,
}

impl PostgresReconStore {
    pub fn new(pool: Pool<Postgres>) -> Self {
        Self { pool }
    }

    async fn set_tenant(&self, tenant_id: Uuid) -> Result<(), ReconciliationError> {
        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;
        Ok(())
    }
}

#[async_trait]
impl ReconciliationStorePort for PostgresReconStore {
    async fn save_run(&self, run: &ReconciliationRun) -> Result<(), ReconciliationError> {
        self.set_tenant(run.tenant_id).await?;

        let status = match run.status {
            ReconciliationStatus::Pending => "pending",
            ReconciliationStatus::Running => "processing",
            ReconciliationStatus::Completed => "completed",
            ReconciliationStatus::Failed => "failed",
            ReconciliationStatus::PartiallyResolved => "completed",
            ReconciliationStatus::Approved => "completed",
        };

        let discrepancy_count = run.discrepancy_count;
        let unmatched_kernel = discrepancy_count;
        let unmatched_provider = 0i32;

        sqlx::query(
            r#"
            INSERT INTO reconciliation.reports (
                report_id, report_reference, reconciliation_type, provider_id,
                period_start, period_end, status,
                kernel_transaction_count, provider_transaction_count, matched_count,
                unmatched_kernel_count, unmatched_provider_count,
                kernel_total_amount, provider_total_amount,
                started_at, completed_at, created_by
            ) VALUES ($1, $2, 'provider_statement', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, NULL)
            ON CONFLICT (report_id) DO UPDATE SET
                status = EXCLUDED.status,
                kernel_transaction_count = EXCLUDED.kernel_transaction_count,
                provider_transaction_count = EXCLUDED.provider_transaction_count,
                matched_count = EXCLUDED.matched_count,
                unmatched_kernel_count = EXCLUDED.unmatched_kernel_count,
                unmatched_provider_count = EXCLUDED.unmatched_provider_count,
                kernel_total_amount = EXCLUDED.kernel_total_amount,
                provider_total_amount = EXCLUDED.provider_total_amount,
                started_at = EXCLUDED.started_at,
                completed_at = EXCLUDED.completed_at
            "#
        )
        .bind(run.run_id)
        .bind(format!("RUN-{}", run.run_id))
        .bind(&run.provider_name)
        .bind(run.period_start.date_naive())
        .bind(run.period_end.date_naive())
        .bind(status)
        .bind(run.total_records)
        .bind(0i32)
        .bind(run.matched_count)
        .bind(unmatched_kernel)
        .bind(unmatched_provider)
        .bind(run.internal_total.to_string())
        .bind(run.external_total.to_string())
        .bind(run.started_at)
        .bind(run.completed_at)
        .execute(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    async fn get_run(&self, run_id: Uuid, tenant_id: Uuid) -> Result<ReconciliationRun, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let row = sqlx::query(
            r#"
            SELECT
                report_id, provider_id, status,
                period_start, period_end,
                kernel_transaction_count, provider_transaction_count,
                matched_count,
                unmatched_kernel_count, unmatched_provider_count,
                kernel_total_amount, provider_total_amount,
                started_at, completed_at,
                created_by
            FROM reconciliation.reports
            WHERE report_id = $1
            "#
        )
        .bind(run_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| match e {
            sqlx::Error::RowNotFound => ReconciliationError::NotFound(format!("Run {} not found", run_id)),
            _ => ReconciliationError::DatabaseError(e.to_string()),
        })?;

        Ok(map_run_row(row, tenant_id)?)
    }

    async fn list_runs(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
        statuses: Vec<ReconciliationStatus>,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<ReconciliationRun>, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let status_strings: Vec<String> = statuses.into_iter().map(|s| {
            match s {
                ReconciliationStatus::Pending => "pending".to_string(),
                ReconciliationStatus::Running => "processing".to_string(),
                ReconciliationStatus::Completed => "completed".to_string(),
                ReconciliationStatus::Failed => "failed".to_string(),
                ReconciliationStatus::PartiallyResolved => "completed".to_string(),
                ReconciliationStatus::Approved => "completed".to_string(),
            }
        }).collect();

        let rows = sqlx::query(
            r#"
            SELECT
                report_id, provider_id, status,
                period_start, period_end,
                kernel_transaction_count, provider_transaction_count,
                matched_count,
                unmatched_kernel_count, unmatched_provider_count,
                kernel_total_amount, provider_total_amount,
                started_at, completed_at,
                created_by
            FROM reconciliation.reports
            WHERE ($1::text IS NULL OR provider_id = $1)
              AND ($2::text[] = '{}' OR status = ANY($2))
              AND period_start >= $3
              AND period_end <= $4
            ORDER BY started_at DESC NULLS LAST
            "#
        )
        .bind(provider_name)
        .bind(&status_strings)
        .bind(from.date_naive())
        .bind(to.date_naive())
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        rows.into_iter()
            .map(|r| map_run_row(r, tenant_id))
            .collect()
    }

    async fn save_item(&self, item: &ReconciliationItem) -> Result<(), ReconciliationError> {
        let mismatch_type = map_discrepancy_to_mismatch(&item.discrepancy_type);
        let resolution_status = if item.resolved { "resolved" } else { "open" };

        sqlx::query(
            r#"
            INSERT INTO reconciliation.mismatches (
                mismatch_id, report_id, mismatch_type,
                kernel_reference, kernel_amount,
                provider_reference, provider_amount,
                amount_difference, discrepancy_reason,
                resolution_status, resolution_notes, resolved_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            ON CONFLICT (mismatch_id) DO UPDATE SET
                mismatch_type = EXCLUDED.mismatch_type,
                kernel_reference = EXCLUDED.kernel_reference,
                kernel_amount = EXCLUDED.kernel_amount,
                provider_reference = EXCLUDED.provider_reference,
                provider_amount = EXCLUDED.provider_amount,
                amount_difference = EXCLUDED.amount_difference,
                discrepancy_reason = EXCLUDED.discrepancy_reason,
                resolution_status = EXCLUDED.resolution_status,
                resolution_notes = EXCLUDED.resolution_notes,
                resolved_at = EXCLUDED.resolved_at
            "#
        )
        .bind(item.item_id)
        .bind(item.run_id)
        .bind(mismatch_type)
        .bind(&item.transaction_id)
        .bind(item.internal_amount.to_string())
        .bind(&item.transaction_id)
        .bind(item.external_amount.to_string())
        .bind(item.difference.to_string())
        .bind(item.notes.as_deref().unwrap_or(""))
        .bind(resolution_status)
        .bind(item.notes.as_deref().unwrap_or(""))
        .bind(item.resolved_at)
        .execute(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    async fn get_items(
        &self,
        run_id: Uuid,
        tenant_id: Uuid,
        discrepancy_types: Vec<DiscrepancyType>,
        unresolved_only: bool,
    ) -> Result<Vec<ReconciliationItem>, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let types: Vec<String> = discrepancy_types.into_iter()
            .map(|t| map_discrepancy_to_mismatch(&t).to_string())
            .collect();

        let rows = sqlx::query(
            r#"
            SELECT
                mismatch_id, report_id, kernel_reference, mismatch_type,
                kernel_amount, provider_amount, amount_difference,
                resolution_status, resolution_notes, resolved_at,
                discrepancy_reason
            FROM reconciliation.mismatches
            WHERE report_id = $1
              AND ($2::text[] = '{}' OR mismatch_type = ANY($2))
              AND ($3 = false OR resolution_status != 'resolved')
            ORDER BY created_at DESC
            "#
        )
        .bind(run_id)
        .bind(&types)
        .bind(unresolved_only)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        rows.into_iter()
            .map(map_item_row)
            .collect()
    }

    async fn get_item(&self, item_id: Uuid, tenant_id: Uuid) -> Result<ReconciliationItem, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let row = sqlx::query(
            r#"
            SELECT
                mismatch_id, report_id, kernel_reference, mismatch_type,
                kernel_amount, provider_amount, amount_difference,
                resolution_status, resolution_notes, resolved_at,
                discrepancy_reason
            FROM reconciliation.mismatches
            WHERE mismatch_id = $1
            "#
        )
        .bind(item_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| match e {
            sqlx::Error::RowNotFound => ReconciliationError::NotFound(format!("Item {} not found", item_id)),
            _ => ReconciliationError::DatabaseError(e.to_string()),
        })?;

        map_item_row(row)
    }

    async fn update_item_resolution(
        &self,
        item_id: Uuid,
        action: ResolutionAction,
        notes: &str,
        resolved_by: &str,
    ) -> Result<(), ReconciliationError> {
        let status = match action {
            ResolutionAction::CorrectInternal | ResolutionAction::CorrectExternal |
            ResolutionAction::CreateAdjustment | ResolutionAction::Ignore | ResolutionAction::Approve => "resolved",
            ResolutionAction::Escalate => "disputed",
        };

        let full_notes = format!("[{}] {}", action.as_str(), notes);

        sqlx::query(
            r#"
            UPDATE reconciliation.mismatches
            SET resolution_status = $1,
                resolution_notes = $2,
                resolved_by = (SELECT account_id FROM core.account_registry WHERE account_number = $3 LIMIT 1),
                resolved_at = NOW()
            WHERE mismatch_id = $4
            "#
        )
        .bind(status)
        .bind(&full_notes)
        .bind(resolved_by)
        .bind(item_id)
        .execute(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    async fn get_matching_rule(&self, rule_id: Uuid, tenant_id: Uuid) -> Result<MatchingRule, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let row = sqlx::query(
            r#"
            SELECT
                rule_id, application_id, rule_code, match_criteria,
                tolerance_absolute, date_tolerance_days, auto_match_enabled, status,
                created_at
            FROM app.matching_rules
            WHERE rule_id = $1
            ORDER BY created_at DESC
            LIMIT 1
            "#
        )
        .bind(rule_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| match e {
            sqlx::Error::RowNotFound => ReconciliationError::NotFound(format!("Rule {} not found", rule_id)),
            _ => ReconciliationError::DatabaseError(e.to_string()),
        })?;

        Ok(map_rule_row(row, tenant_id)?)
    }

    async fn list_matching_rules(
        &self,
        tenant_id: Uuid,
        provider_name: Option<&str>,
    ) -> Result<Vec<MatchingRule>, ReconciliationError> {
        self.set_tenant(tenant_id).await?;

        let rows = sqlx::query(
            r#"
            SELECT
                rule_id, application_id, rule_code, match_criteria,
                tolerance_absolute, date_tolerance_days, auto_match_enabled, status,
                created_at
            FROM app.matching_rules
            WHERE application_id = $1
              AND ($2::text IS NULL OR source_entity_type ILIKE $2)
            ORDER BY execution_order
            "#
        )
        .bind(tenant_id)
        .bind(provider_name)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?;

        rows.into_iter()
            .map(|r| map_rule_row(r, tenant_id))
            .collect()
    }
}

fn map_run_row(row: sqlx::postgres::PgRow, tenant_id: Uuid) -> Result<ReconciliationRun, ReconciliationError> {
    let status_str: String = row.try_get("status").unwrap_or_default();
    let status = match status_str.to_lowercase().as_str() {
        "pending" => ReconciliationStatus::Pending,
        "processing" => ReconciliationStatus::Running,
        "completed" => ReconciliationStatus::Completed,
        "failed" => ReconciliationStatus::Failed,
        _ => ReconciliationStatus::Pending,
    };

    let provider: String = row.try_get("provider_id").unwrap_or_default();

    let kernel_total_str: String = row.try_get("kernel_total_amount").unwrap_or_else(|_| "0".to_string());
    let provider_total_str: String = row.try_get("provider_total_amount").unwrap_or_else(|_| "0".to_string());
    let unmatched_kernel: i32 = row.try_get("unmatched_kernel_count").unwrap_or(0);
    let unmatched_provider: i32 = row.try_get("unmatched_provider_count").unwrap_or(0);

    Ok(ReconciliationRun {
        run_id: row.try_get("report_id").map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?,
        tenant_id,
        provider_name: provider,
        status,
        period_start: row.try_get::<chrono::NaiveDate, _>("period_start")
            .map(|d| d.and_hms_opt(0, 0, 0).unwrap_or_default().and_utc())
            .unwrap_or_else(|_| Utc::now()),
        period_end: row.try_get::<chrono::NaiveDate, _>("period_end")
            .map(|d| d.and_hms_opt(0, 0, 0).unwrap_or_default().and_utc())
            .unwrap_or_else(|_| Utc::now()),
        total_records: row.try_get("kernel_transaction_count").unwrap_or(0)
            + row.try_get("provider_transaction_count").unwrap_or(0),
        matched_count: row.try_get("matched_count").unwrap_or(0),
        discrepancy_count: unmatched_kernel + unmatched_provider,
        resolved_count: 0,
        internal_total: kernel_total_str.parse().unwrap_or(Decimal::ZERO),
        external_total: provider_total_str.parse().unwrap_or(Decimal::ZERO),
        discrepancy_amount: (kernel_total_str.parse::<Decimal>().unwrap_or(Decimal::ZERO)
            - provider_total_str.parse::<Decimal>().unwrap_or(Decimal::ZERO)).abs(),
        started_at: row.try_get("started_at").ok(),
        completed_at: row.try_get("completed_at").ok(),
        initiated_by: row.try_get::<Option<String>, _>("created_by").unwrap_or_default().unwrap_or_default(),
        approved_by: None,
        approved_at: None,
    })
}

fn map_item_row(row: sqlx::postgres::PgRow) -> Result<ReconciliationItem, ReconciliationError> {
    let dtype_str: String = row.try_get("mismatch_type").unwrap_or_default();
    let discrepancy_type = match dtype_str.to_lowercase().as_str() {
        "kernel_only" => DiscrepancyType::MissingInternal,
        "provider_only" => DiscrepancyType::MissingExternal,
        "amount_diff" => DiscrepancyType::AmountMismatch,
        "status_diff" => DiscrepancyType::StatusMismatch,
        "duplicate" => DiscrepancyType::DuplicateInternal,
        "fee_diff" => DiscrepancyType::FeeMismatch,
        "date_mismatch" => DiscrepancyType::TimestampMismatch,
        _ => DiscrepancyType::AmountMismatch,
    };

    let status_str: Option<String> = row.try_get("resolution_status").ok();
    let resolved = status_str.as_ref().map(|s| s == "resolved").unwrap_or(false);

    let resolved_at: Option<DateTime<Utc>> = row.try_get("resolved_at").ok();

    let internal_amount_str: String = row.try_get("kernel_amount").unwrap_or_else(|_| "0".to_string());
    let external_amount_str: String = row.try_get("provider_amount").unwrap_or_else(|_| "0".to_string());
    let discrepancy_amount_str: String = row.try_get("amount_difference").unwrap_or_else(|_| "0".to_string());

    Ok(ReconciliationItem {
        item_id: row.try_get("mismatch_id").map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?,
        run_id: row.try_get("report_id").map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?,
        transaction_id: row.try_get::<String, _>("kernel_reference").unwrap_or_default(),
        discrepancy_type,
        internal_status: String::new(),
        external_status: String::new(),
        internal_amount: internal_amount_str.parse().unwrap_or(Decimal::ZERO),
        external_amount: external_amount_str.parse().unwrap_or(Decimal::ZERO),
        difference: discrepancy_amount_str.parse().unwrap_or(Decimal::ZERO),
        resolved,
        resolution_action: status_str.and_then(|s| match s.as_str() {
            "resolved" => Some(ResolutionAction::Approve),
            "disputed" => Some(ResolutionAction::Escalate),
            "investigating" => Some(ResolutionAction::Ignore),
            _ => None,
        }),
        resolved_by: row.try_get("resolution_notes").ok().and_then(|n: String| {
            n.split(']').next().map(|s| s.trim_start_matches('[').to_string())
        }),
        resolved_at,
        notes: row.try_get("resolution_notes").ok(),
    })
}

fn map_discrepancy_to_mismatch(dt: &DiscrepancyType) -> &'static str {
    match dt {
        DiscrepancyType::MissingInternal => "kernel_only",
        DiscrepancyType::MissingExternal => "provider_only",
        DiscrepancyType::AmountMismatch => "amount_diff",
        DiscrepancyType::StatusMismatch => "status_diff",
        DiscrepancyType::DuplicateInternal => "duplicate",
        DiscrepancyType::DuplicateExternal => "duplicate",
        DiscrepancyType::FeeMismatch => "fee_diff",
        DiscrepancyType::TimestampMismatch => "date_mismatch",
        DiscrepancyType::CurrencyMismatch => "amount_diff",
    }
}

fn map_rule_row(row: sqlx::postgres::PgRow, tenant_id: Uuid) -> Result<MatchingRule, ReconciliationError> {
    let criteria_json: Option<serde_json::Value> = row.try_get("match_criteria").ok();
    let match_fields = match criteria_json {
        Some(serde_json::Value::Object(map)) => map.keys().cloned().collect(),
        _ => vec![],
    };

    let status: String = row.try_get("status").unwrap_or_default();
    let tolerance_str: String = row.try_get("tolerance_absolute").unwrap_or_else(|_| "0".to_string());

    Ok(MatchingRule {
        rule_id: row.try_get("rule_id").map_err(|e| ReconciliationError::DatabaseError(e.to_string()))?,
        tenant_id,
        provider_name: row.try_get::<String, _>("source_entity_type").unwrap_or_default(),
        rule_name: row.try_get("rule_code").unwrap_or_default(),
        match_fields,
        tolerance_amount: tolerance_str.parse().unwrap_or(Decimal::ZERO),
        tolerance_time_seconds: row.try_get::<i32, _>("date_tolerance_days").unwrap_or(0) * 86400,
        auto_resolve: row.try_get("auto_match_enabled").unwrap_or(false),
        is_active: status == "active",
        created_at: row.try_get("created_at").ok(),
        updated_at: None,
    })
}
