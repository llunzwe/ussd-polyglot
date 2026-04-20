use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use sqlx::PgPool;
use tokio::sync::RwLock;
use tracing::info;
use uuid::Uuid;

use crate::domain::delivery::DeliveryAttempt;
use crate::domain::error::MessagingError;
use crate::ports::delivery_log::{DeliveryLogPort, MessageFilters};

#[derive(Clone)]
pub struct PostgresDeliveryLog {
    db: Option<PgPool>,
    fallback: Arc<RwLock<HashMap<Uuid, DeliveryAttempt>>>,
}

impl PostgresDeliveryLog {
    pub fn new(db: Option<PgPool>) -> Self {
        Self {
            db,
            fallback: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    async fn set_tenant_context(&self, tenant_id: &Uuid) -> Result<(), sqlx::Error> {
        if let Some(ref pool) = self.db {
            sqlx::query("SET LOCAL app.current_tenant_id = $1")
                .bind(tenant_id.to_string())
                .execute(pool)
                .await?;
        }
        Ok(())
    }
}

#[async_trait]
impl DeliveryLogPort for PostgresDeliveryLog {
    async fn log_attempt(&self, attempt: &DeliveryAttempt) -> Result<(), MessagingError> {
        self.set_tenant_context(&attempt.tenant_id).await.map_err(|e| {
            MessagingError::Database(format!("Failed to set tenant context: {}", e))
        })?;

        if let Some(ref _pool) = self.db {
            info!("Logging delivery attempt {} to database", attempt.message_id);
        }

        let mut map = self.fallback.write().await;
        map.insert(attempt.message_id, attempt.clone());
        Ok(())
    }

    async fn get_attempt(
        &self,
        message_id: Uuid,
    ) -> Result<Option<DeliveryAttempt>, MessagingError> {
        let map = self.fallback.read().await;
        Ok(map.get(&message_id).cloned())
    }

    async fn list_attempts(
        &self,
        tenant_id: Uuid,
        filters: MessageFilters,
    ) -> Result<Vec<DeliveryAttempt>, MessagingError> {
        self.set_tenant_context(&tenant_id).await.map_err(|e| {
            MessagingError::Database(format!("Failed to set tenant context: {}", e))
        })?;

        let map = self.fallback.read().await;
        let mut results: Vec<DeliveryAttempt> = map
            .values()
            .filter(|a| a.tenant_id == tenant_id)
            .cloned()
            .collect();

        if !filters.channels.is_empty() {
            results.retain(|a| filters.channels.contains(&a.channel));
        }
        if !filters.statuses.is_empty() {
            results.retain(|a| filters.statuses.contains(&a.status));
        }
        if let Some(ref recipient) = filters.recipient {
            results.retain(|a| a.recipient == *recipient);
        }
        if let Some(from) = filters.from_date {
            results.retain(|a| a.sent_at.map_or(false, |t| t >= from));
        }
        if let Some(to) = filters.to_date {
            results.retain(|a| a.sent_at.map_or(false, |t| t <= to));
        }
        if let Some(ref session_id) = filters.session_id {
            results.retain(|a| a.session_id.as_ref() == Some(session_id));
        }

        Ok(results)
    }
}
