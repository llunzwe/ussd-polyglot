use async_trait::async_trait;
use chrono::{DateTime, Utc};

use crate::domain::error::ReconciliationError;
use crate::domain::transaction::ExternalTransaction;
use crate::ports::external_statement::ExternalStatementPort;

#[derive(Debug, Clone)]
pub struct ProviderStatementAdapter;

impl ProviderStatementAdapter {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl ExternalStatementPort for ProviderStatementAdapter {
    async fn fetch_external_transactions(
        &self,
        provider_name: &str,
        _from: DateTime<Utc>,
        _to: DateTime<Utc>,
    ) -> Result<Vec<ExternalTransaction>, ReconciliationError> {
        match provider_name.to_lowercase().as_str() {
            "ecocash" | "onemoney" | "telecash" => {
                // Stub adapters for provider statement APIs.
                Ok(vec![])
            }
            _ => Err(ReconciliationError::ProviderError(format!(
                "Unknown provider: {}",
                provider_name
            ))),
        }
    }
}
