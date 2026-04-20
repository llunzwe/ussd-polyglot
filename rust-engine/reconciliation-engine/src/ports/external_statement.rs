use async_trait::async_trait;
use chrono::{DateTime, Utc};

use crate::domain::error::ReconciliationError;
use crate::domain::transaction::ExternalTransaction;

#[async_trait]
pub trait ExternalStatementPort: Send + Sync {
    async fn fetch_external_transactions(
        &self,
        provider_name: &str,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<ExternalTransaction>, ReconciliationError>;
}
