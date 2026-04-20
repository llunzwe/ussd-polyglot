use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq)]
pub enum ReconciliationError {
    #[error("Invalid argument: {0}")]
    InvalidArgument(String),

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Database error: {0}")]
    DatabaseError(String),

    #[error("Provider error: {0}")]
    ProviderError(String),

    #[error("Reconciliation already running")]
    AlreadyRunning,

    #[error("Invalid status transition from {from} to {to}")]
    InvalidStatusTransition { from: String, to: String },

    #[error("Store error: {0}")]
    StoreError(String),
}
