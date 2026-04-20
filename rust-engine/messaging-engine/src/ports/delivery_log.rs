use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{delivery::DeliveryAttempt, error::MessagingError};

#[derive(Debug, Clone, Default)]
pub struct MessageFilters {
    pub channels: Vec<crate::domain::message::MessageChannel>,
    pub statuses: Vec<crate::domain::delivery::DeliveryStatus>,
    pub recipient: Option<String>,
    pub from_date: Option<chrono::DateTime<chrono::Utc>>,
    pub to_date: Option<chrono::DateTime<chrono::Utc>>,
    pub session_id: Option<String>,
}

#[async_trait]
pub trait DeliveryLogPort: Send + Sync {
    async fn log_attempt(&self, attempt: &DeliveryAttempt) -> Result<(), MessagingError>;
    async fn get_attempt(&self, message_id: Uuid) -> Result<Option<DeliveryAttempt>, MessagingError>;
    async fn list_attempts(
        &self,
        tenant_id: Uuid,
        filters: MessageFilters,
    ) -> Result<Vec<DeliveryAttempt>, MessagingError>;
}
