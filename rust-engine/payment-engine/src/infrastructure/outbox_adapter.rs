use sqlx::PgPool;
use uuid::Uuid;
use serde_json::Value;

pub struct PostgresOutboxAdapter {
    pool: PgPool,
}

impl PostgresOutboxAdapter {
    pub fn new(pool: PgPool) -> Self { Self { pool } }
    
    pub async fn write_outbox(&self, event_type: &str, aggregate_type: &str, aggregate_id: Uuid, payload: Value, tenant_id: Uuid) -> Result<(), sqlx::Error> {
        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id.to_string())
            .execute(&self.pool)
            .await?;

        let topic_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT topic_id FROM events.cdc_topics WHERE is_active = true LIMIT 1"
        )
        .fetch_optional(&self.pool)
        .await?;

        let topic_id = topic_id.unwrap_or_else(|| Uuid::nil());

        sqlx::query(
            r#"
            INSERT INTO events.cdc_outbox (topic_id, event_type, aggregate_type, aggregate_id, payload, created_at)
            VALUES ($1, $2, $3, $4, $5, NOW())
            "#
        )
        .bind(topic_id)
        .bind(event_type)
        .bind(aggregate_type)
        .bind(aggregate_id)
        .bind(payload)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
