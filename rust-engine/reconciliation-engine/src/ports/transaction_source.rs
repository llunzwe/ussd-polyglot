use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::error::ReconciliationError;
use crate::domain::transaction::InternalTransaction;

#[async_trait]
pub trait TransactionSourcePort: Send + Sync {
    async fn fetch_internal_transactions(
        &self,
        tenant_id: Uuid,
        provider_name: &str,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<InternalTransaction>, ReconciliationError>;
}
