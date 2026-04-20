use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::{FromRow, PgPool};
use uuid::Uuid;

#[derive(Debug, Clone, FromRow)]
pub struct DbEvent {
    pub event_id: Uuid,
    pub event_type: String,
    pub aggregate_type: String,
    pub aggregate_id: Uuid,
    pub version: i64,
    pub payload: Value,
    pub tenant_id: Uuid,
    pub session_id: Uuid,
    pub correlation_id: Option<String>,
    pub causation_id: Option<String>,
    pub idempotency_key: Option<String>,
    pub record_hash: String,
    pub previous_hash: Option<String>,
    pub occurred_at: DateTime<Utc>,
    pub tracing: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct PgEventStore {
    pool: PgPool,
}

impl PgEventStore {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn fetch_events(
        &self,
        session_id: Uuid,
        tenant_id: Uuid,
        limit: i32,
    ) -> Result<Vec<DbEvent>, sqlx::Error> {
        let mut tx = self.pool.begin().await?;

        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id)
            .execute(&mut *tx)
            .await?;

        let events = sqlx::query_as::<_, DbEvent>(
            r#"
            SELECT
                event_id,
                event_type,
                aggregate_type,
                aggregate_id,
                version,
                payload,
                tenant_id,
                session_id,
                correlation_id,
                causation_id,
                idempotency_key,
                record_hash,
                previous_hash,
                occurred_at,
                tracing
            FROM events.event_store
            WHERE session_id = $1
            ORDER BY version ASC
            LIMIT $2
            "#,
        )
        .bind(session_id)
        .bind(i64::from(limit))
        .fetch_all(&mut *tx)
        .await?;

        tx.commit().await?;
        Ok(events)
    }
}
