use thiserror::Error;

#[derive(Debug, Error)]
pub enum AuditError {
    #[error("Database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("Event not found: {0}")]
    EventNotFound(String),

    #[error("Batch not found for date: {0}")]
    BatchNotFound(String),

    #[error("Hash chain broken at transaction: {0}")]
    HashChainBroken(String),

    #[error("Invalid date range: {0}")]
    InvalidDateRange(String),

    #[error("Export generation failed: {0}")]
    ExportFailed(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Internal error: {0}")]
    Internal(String),
}

impl From<AuditError> for tonic::Status {
    fn from(err: AuditError) -> Self {
        match err {
            AuditError::EventNotFound(_) | AuditError::BatchNotFound(_) => {
                tonic::Status::not_found(err.to_string())
            }
            AuditError::HashChainBroken(_) => tonic::Status::failed_precondition(err.to_string()),
            AuditError::InvalidDateRange(_) => tonic::Status::invalid_argument(err.to_string()),
            _ => tonic::Status::internal(err.to_string()),
        }
    }
}
