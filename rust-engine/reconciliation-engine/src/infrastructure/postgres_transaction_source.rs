use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::{Pool, Postgres};
use uuid::Uuid;

use crate::domain::error::ReconciliationError;
use crate::domain::transaction::InternalTransaction;
use crate::ports::transaction_source::TransactionSourcePort;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct PostgresTransactionSource {
    pool: Pool<Postgres>,
}

impl PostgresTransactionSource {
    pub fn new(pool: Pool<Postgres>) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl TransactionSourcePort for PostgresTransactionSource {
    async fn fetch_internal_transactions(
        &self,
        _tenant_id: Uuid,
        _provider_name: &str,
        _from: DateTime<Utc>,
        _to: DateTime<Utc>,
    ) -> Result<Vec<InternalTransaction>, ReconciliationError> {
        // Placeholder: query core.transaction_log or core.transactions.
        // For now, return an empty vector so the crate compiles.
        Ok(vec![])
    }
}
