use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::{Pool, Postgres};
use uuid::Uuid;

use crate::domain::error::DomainError;

#[derive(Debug, Clone)]
pub struct OutboxEntry {
    pub outbox_id: i64,
    pub event_type: String,
    pub payload: Value,
    pub aggregate_id: Uuid,
    pub idempotency_key: String,
    pub tenant_id: Uuid,
    pub occurred_at: DateTime<Utc>,
    pub processed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct OutboxRepository {
    pool: Pool<Postgres>,
}

impl OutboxRepository {
    pub fn new(pool: Pool<Postgres>) -> Self {
        Self { pool }
    }

    pub async fn append_outbox(
        &self,
        event_type: &str,
        aggregate_id: Uuid,
        payload: Value,
        _idempotency_key: &str,
        tenant_id: Uuid,
    ) -> Result<(), DomainError> {
        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        let topic_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT topic_id FROM events.cdc_topics WHERE is_active = true LIMIT 1"
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        let topic_id = topic_id.unwrap_or_else(|| Uuid::nil());

        sqlx::query(
            r#"
            INSERT INTO events.cdc_outbox (topic_id, event_type, aggregate_type, aggregate_id, payload, created_at)
            VALUES ($1, $2, $3, $4, $5, NOW())
            "#
        )
        .bind(topic_id)
        .bind(event_type)
        .bind("payment")
        .bind(aggregate_id)
        .bind(payload)
        .execute(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    pub async fn get_unprocessed(&self, limit: i64) -> Result<Vec<OutboxEntry>, DomainError> {
        let rows = sqlx::query_as::<_, OutboxRow>(
            r#"
            SELECT
                outbox_id,
                event_type,
                payload,
                aggregate_id,
                '' as idempotency_key,
                aggregate_id as tenant_id,
                created_at as occurred_at,
                published_at as processed_at
            FROM events.cdc_outbox
            WHERE published = false
            ORDER BY created_at ASC
            LIMIT $1
            "#,
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        Ok(rows.into_iter().map(Into::into).collect())
    }
}

#[derive(sqlx::FromRow)]
struct OutboxRow {
    outbox_id: Uuid,
    event_type: String,
    payload: Value,
    aggregate_id: Uuid,
    idempotency_key: String,
    tenant_id: Uuid,
    occurred_at: DateTime<Utc>,
    processed_at: Option<DateTime<Utc>>,
}

impl From<OutboxRow> for OutboxEntry {
    fn from(row: OutboxRow) -> Self {
        Self {
            outbox_id: row.outbox_id.as_u128() as i64,
            event_type: row.event_type,
            payload: row.payload,
            aggregate_id: row.aggregate_id,
            idempotency_key: row.idempotency_key,
            tenant_id: row.tenant_id,
            occurred_at: row.occurred_at,
            processed_at: row.processed_at,
        }
    }
}
