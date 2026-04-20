use chrono::{DateTime, NaiveDate, Utc};
use sqlx::{PgPool, Row};
use tracing::info;
use uuid::Uuid;

use crate::domain::error::AuditError;
use crate::domain::merkle::{build_merkle_tree, sha256};

async fn set_tenant_context(pool: &PgPool, tenant_id: &Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("SET LOCAL app.current_tenant_id = $1")
        .bind(tenant_id.to_string())
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(Debug, Clone)]
pub struct EventRecord {
    pub event_id: Uuid,
    pub event_type: String,
    pub sequence_number: i64,
    pub payload: serde_json::Value,
    pub record_hash: String,
    pub previous_hash: Option<String>,
    pub occurred_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct TransactionRecord {
    pub transaction_id: i64,
    pub transaction_uuid: Uuid,
    pub record_hash: String,
    pub previous_hash: Option<String>,
    pub committed_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct BatchHashRecord {
    pub batch_id: Uuid,
    pub batch_date: NaiveDate,
    pub batch_hash: String,
    pub record_count: i32,
    pub source_data_hash: String,
    pub computed_at: DateTime<Utc>,
    pub previous_batch_hash: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuditTrailRecord {
    pub audit_id: Uuid,
    pub event_type: String,
    pub action: String,
    pub old_data: Option<serde_json::Value>,
    pub new_data: Option<serde_json::Value>,
    pub timestamp: DateTime<Utc>,
    pub record_hash: String,
    pub previous_hash: Option<String>,
}

#[derive(Clone)]
pub struct AuditRepository {
    pool: PgPool,
}

impl AuditRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Fetch events within a date range for Merkle tree computation.
    pub async fn fetch_events_for_range(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<EventRecord>, AuditError> {
        let rows = sqlx::query(
            r#"
            SELECT 
                event_id,
                event_type,
                sequence_number,
                payload,
                encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                lag(encode(digest(payload::text, 'sha256'), 'hex')) over (order by sequence_number) as previous_hash,
                occurred_at
            FROM events.event_store
            WHERE occurred_at >= $1 AND occurred_at < $2
            ORDER BY sequence_number ASC
            "#,
        )
        .bind(from)
        .bind(to)
        .fetch_all(&self.pool)
        .await?;

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            records.push(EventRecord {
                event_id: row.try_get("event_id")?,
                event_type: row.try_get("event_type")?,
                sequence_number: row.try_get("sequence_number")?,
                payload: row.try_get("payload")?,
                record_hash: row.try_get("record_hash")?,
                previous_hash: row.try_get("previous_hash")?,
                occurred_at: row.try_get("occurred_at")?,
            });
        }
        Ok(records)
    }

    /// Fetch events by IDs for targeted Merkle proof generation.
    pub async fn fetch_events_by_ids(
        &self,
        event_ids: &[Uuid],
    ) -> Result<Vec<EventRecord>, AuditError> {
        if event_ids.is_empty() {
            return Ok(vec![]);
        }

        let rows = sqlx::query(
            r#"
            SELECT 
                event_id,
                event_type,
                sequence_number,
                payload,
                encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                occurred_at
            FROM events.event_store
            WHERE event_id = ANY($1)
            ORDER BY sequence_number ASC
            "#,
        )
        .bind(event_ids)
        .fetch_all(&self.pool)
        .await?;

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            records.push(EventRecord {
                event_id: row.try_get("event_id")?,
                event_type: row.try_get("event_type")?,
                sequence_number: row.try_get("sequence_number")?,
                payload: row.try_get("payload")?,
                record_hash: row.try_get("record_hash")?,
                previous_hash: None,
                occurred_at: row.try_get("occurred_at")?,
            });
        }
        Ok(records)
    }

    /// Fetch a single event by ID or sequence number.
    pub async fn fetch_event(
        &self,
        event_id: Option<Uuid>,
        sequence_number: Option<i64>,
    ) -> Result<Option<EventRecord>, AuditError> {
        let row = if let Some(id) = event_id {
            sqlx::query(
                r#"
                SELECT 
                    event_id,
                    event_type,
                    sequence_number,
                    payload,
                    encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                    occurred_at
                FROM events.event_store
                WHERE event_id = $1
                LIMIT 1
                "#,
            )
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
        } else if let Some(seq) = sequence_number {
            sqlx::query(
                r#"
                SELECT 
                    event_id,
                    event_type,
                    sequence_number,
                    payload,
                    encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                    occurred_at
                FROM events.event_store
                WHERE sequence_number = $1
                LIMIT 1
                "#,
            )
            .bind(seq)
            .fetch_optional(&self.pool)
            .await?
        } else {
            return Ok(None);
        };

        Ok(row.map(|r| EventRecord {
            event_id: r.try_get("event_id").unwrap_or_default(),
            event_type: r.try_get("event_type").unwrap_or_default(),
            sequence_number: r.try_get("sequence_number").unwrap_or_default(),
            payload: r.try_get("payload").unwrap_or_default(),
            record_hash: r.try_get("record_hash").unwrap_or_default(),
            previous_hash: None,
            occurred_at: r.try_get("occurred_at").unwrap_or_else(|_| Utc::now()),
        }))
    }

    /// Fetch transaction log records for chain verification.
    pub async fn fetch_transactions_for_chain(
        &self,
        transaction_uuid: Uuid,
        max_depth: i32,
    ) -> Result<Vec<TransactionRecord>, AuditError> {
        let rows = sqlx::query(
            r#"
            WITH RECURSIVE chain AS (
                SELECT 
                    transaction_id,
                    transaction_uuid,
                    record_hash,
                    previous_hash,
                    committed_at,
                    1 as depth
                FROM core.transaction_log
                WHERE transaction_uuid = $1
                
                UNION ALL
                
                SELECT 
                    t.transaction_id,
                    t.transaction_uuid,
                    t.record_hash,
                    t.previous_hash,
                    t.committed_at,
                    c.depth + 1
                FROM core.transaction_log t
                JOIN chain c ON t.record_hash = c.previous_hash
                WHERE c.depth < $2
            )
            SELECT * FROM chain ORDER BY depth ASC
            "#,
        )
        .bind(transaction_uuid)
        .bind(max_depth)
        .fetch_all(&self.pool)
        .await?;

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            records.push(TransactionRecord {
                transaction_id: row.try_get("transaction_id")?,
                transaction_uuid: row.try_get("transaction_uuid")?,
                record_hash: row.try_get("record_hash")?,
                previous_hash: row.try_get("previous_hash")?,
                committed_at: row.try_get("committed_at")?,
            });
        }
        Ok(records)
    }

    /// Fetch or compute batch hash for a given date.
    pub async fn get_or_compute_batch_hash(
        &self,
        date: NaiveDate,
    ) -> Result<BatchHashRecord, AuditError> {
        // Try existing first
        let existing = sqlx::query(
            r#"
            SELECT 
                batch_id, batch_date, batch_hash, record_count,
                source_data_hash, computed_at, previous_batch_hash
            FROM integrity.batch_hashes
            WHERE batch_date = $1
            LIMIT 1
            "#,
        )
        .bind(date)
        .fetch_optional(&self.pool)
        .await?;

        if let Some(row) = existing {
            return Ok(BatchHashRecord {
                batch_id: row.try_get("batch_id")?,
                batch_date: row.try_get("batch_date")?,
                batch_hash: row.try_get("batch_hash")?,
                record_count: row.try_get("record_count")?,
                source_data_hash: row.try_get("source_data_hash")?,
                computed_at: row.try_get("computed_at")?,
                previous_batch_hash: row.try_get("previous_batch_hash")?,
            });
        }

        // Compute new batch hash from events (not transactions, since events are the SSOT)
        let from = date.and_hms_opt(0, 0, 0).unwrap().and_utc();
        let to = from + chrono::Duration::days(1);
        let events = self.fetch_events_for_range(from, to).await?;

        let leaves: Vec<Vec<u8>> = events
            .iter()
            .map(|e| sha256(e.record_hash.as_bytes()))
            .collect();
        let (root, _) = build_merkle_tree(&leaves);
        let batch_hash = hex::encode(&root);
        let source_data_hash = if events.is_empty() {
            hex::encode(sha256(b""))
        } else {
            hex::encode(sha256(
                &events
                    .iter()
                    .flat_map(|e| e.record_hash.as_bytes().to_vec())
                    .collect::<Vec<u8>>(),
            ))
        };

        // Get previous batch hash
        let prev_row = sqlx::query(
            r#"
            SELECT batch_hash 
            FROM integrity.batch_hashes 
            WHERE batch_date < $1 
            ORDER BY batch_date DESC 
            LIMIT 1
            "#,
        )
        .bind(date)
        .fetch_optional(&self.pool)
        .await?;
        let previous_batch_hash: Option<String> =
            prev_row.and_then(|r| r.try_get("batch_hash").ok());

        let batch_id = Uuid::new_v4();
        let computed_at = Utc::now();

        sqlx::query(
            r#"
            INSERT INTO integrity.batch_hashes (
                batch_id, batch_date, period_type, batch_hash, record_count,
                source_data_hash, computed_at, previous_batch_hash
            ) VALUES ($1, $2, 'daily', $3, $4, $5, $6, $7)
            ON CONFLICT (batch_date) DO UPDATE SET
                batch_hash = EXCLUDED.batch_hash,
                record_count = EXCLUDED.record_count,
                source_data_hash = EXCLUDED.source_data_hash,
                computed_at = EXCLUDED.computed_at,
                previous_batch_hash = EXCLUDED.previous_batch_hash
            "#,
        )
        .bind(batch_id)
        .bind(date)
        .bind(&batch_hash)
        .bind(events.len() as i32)
        .bind(&source_data_hash)
        .bind(computed_at)
        .bind(&previous_batch_hash)
        .execute(&self.pool)
        .await?;

        info!(batch_date = %date, batch_hash = %batch_hash, record_count = events.len(), "computed batch hash");

        Ok(BatchHashRecord {
            batch_id,
            batch_date: date,
            batch_hash,
            record_count: events.len() as i32,
            source_data_hash,
            computed_at,
            previous_batch_hash,
        })
    }

    /// Fetch audit trail entries for a record.
    pub async fn fetch_audit_trail(
        &self,
        record_id: Uuid,
        table_name: &str,
        limit: i32,
        offset: i32,
    ) -> Result<Vec<AuditTrailRecord>, AuditError> {
        let rows = sqlx::query(
            r#"
            SELECT 
                audit_id,
                operation as event_type,
                operation as action,
                old_data,
                new_data,
                changed_at as timestamp,
                record_hash,
                previous_hash
            FROM audit.change_log
            WHERE record_id = $1 AND table_name = $2
            ORDER BY changed_at DESC
            LIMIT $3 OFFSET $4
            "#,
        )
        .bind(record_id)
        .bind(table_name)
        .bind(limit)
        .bind(offset)
        .fetch_all(&self.pool)
        .await?;

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            records.push(AuditTrailRecord {
                audit_id: row.try_get("audit_id")?,
                event_type: row.try_get("event_type")?,
                action: row.try_get("action")?,
                old_data: row.try_get("old_data")?,
                new_data: row.try_get("new_data")?,
                timestamp: row.try_get("timestamp")?,
                record_hash: row.try_get("record_hash")?,
                previous_hash: row.try_get("previous_hash")?,
            });
        }
        Ok(records)
    }

    /// Stream audit events from event_store for a date range.
    pub async fn stream_audit_events(
        &self,
        from: DateTime<Utc>,
        event_types: &[String],
    ) -> Result<Vec<EventRecord>, AuditError> {
        let rows = if event_types.is_empty() {
            sqlx::query(
                r#"
                SELECT 
                    event_id,
                    event_type,
                    sequence_number,
                    payload,
                    encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                    occurred_at
                FROM events.event_store
                WHERE occurred_at >= $1
                ORDER BY sequence_number ASC
                "#,
            )
            .bind(from)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query(
                r#"
                SELECT 
                    event_id,
                    event_type,
                    sequence_number,
                    payload,
                    encode(digest(payload::text, 'sha256'), 'hex') as record_hash,
                    occurred_at
                FROM events.event_store
                WHERE occurred_at >= $1 AND event_type = ANY($2)
                ORDER BY sequence_number ASC
                "#,
            )
            .bind(from)
            .bind(event_types)
            .fetch_all(&self.pool)
            .await?
        };

        let mut records = Vec::with_capacity(rows.len());
        for row in rows {
            records.push(EventRecord {
                event_id: row.try_get("event_id")?,
                event_type: row.try_get("event_type")?,
                sequence_number: row.try_get("sequence_number")?,
                payload: row.try_get("payload")?,
                record_hash: row.try_get("record_hash")?,
                previous_hash: None,
                occurred_at: row.try_get("occurred_at")?,
            });
        }
        Ok(records)
    }

    /// Create an audit export record.
    pub async fn create_audit_export(
        &self,
        application_id: Uuid,
        requested_by: Uuid,
        scope_type: &str,
        criteria: serde_json::Value,
        file_checksum: &str,
    ) -> Result<(Uuid, String), AuditError> {
        set_tenant_context(&self.pool, &application_id).await?;
        let export_id = Uuid::new_v4();
        let reference = format!("AUD-{}", hex::encode(uuid::Uuid::new_v4().as_bytes())[..16].to_string());
        let file_location = format!("/exports/{}.json", reference);

        sqlx::query(
            r#"
            INSERT INTO integrity.audit_trail_exports (
                export_id, export_reference, application_id, requested_by,
                scope_type, scope_criteria, file_location, file_format,
                file_checksum_sha256, signature, signature_algorithm
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'json', $8, gen_random_bytes(64), 'ed25519')
            "#,
        )
        .bind(export_id)
        .bind(&reference)
        .bind(application_id)
        .bind(requested_by)
        .bind(scope_type)
        .bind(criteria)
        .bind(&file_location)
        .bind(file_checksum)
        .execute(&self.pool)
        .await?;

        Ok((export_id, reference))
    }

    /// Update batch hash record with Ed25519 signature.
    pub async fn update_batch_signature(
        &self,
        batch_id: Uuid,
        signature: &[u8],
        key_id: &str,
    ) -> Result<(), AuditError> {
        sqlx::query(
            r#"
            UPDATE integrity.batch_hashes
            SET signature = $1,
                signature_algorithm = 'ed25519',
                key_id = $3,
                computed_at = NOW()
            WHERE batch_id = $2
            "#,
        )
        .bind(signature)
        .bind(batch_id)
        .bind(key_id)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    /// Record a consistency check result.
    pub async fn record_consistency_check(
        &self,
        check_type: &str,
        date_from: NaiveDate,
        date_to: NaiveDate,
        status: &str,
        records_checked: i32,
        records_failed: i32,
        failure_details: Option<serde_json::Value>,
        duration_ms: i32,
    ) -> Result<(), AuditError> {
        sqlx::query(
            r#"
            INSERT INTO integrity.consistency_checks (
                check_type, date_from, date_to, status, records_checked,
                records_failed, failure_details, started_at, completed_at, duration_ms
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW(), $8)
            "#,
        )
        .bind(check_type)
        .bind(date_from)
        .bind(date_to)
        .bind(status)
        .bind(records_checked)
        .bind(records_failed)
        .bind(failure_details)
        .bind(duration_ms)
        .execute(&self.pool)
        .await?;

        Ok(())
    }
}
