use thiserror::Error;

#[derive(Debug, Clone, Error)]
pub enum MessagingError {
    #[error("Invalid phone number: {0}")]
    InvalidPhone(String),

    #[error("Provider unavailable: {0}")]
    ProviderUnavailable(String),

    #[error("Rate limit exceeded for tenant: {0}")]
    RateLimitExceeded(String),

    #[error("Template not found: {0}")]
    TemplateNotFound(String),

    #[error("Database error: {0}")]
    Database(String),

    #[error("Serialization error: {0}")]
    Serialization(String),

    #[error("Internal error: {0}")]
    Internal(String),

    #[error("Provider error: {0}")]
    ProviderError(String),

    #[error("Validation error: {0}")]
    Validation(String),
}

impl From<MessagingError> for tonic::Status {
    fn from(err: MessagingError) -> Self {
        match err {
            MessagingError::InvalidPhone(_) | MessagingError::Validation(_) => {
                tonic::Status::invalid_argument(err.to_string())
            }
            MessagingError::TemplateNotFound(_) => tonic::Status::not_found(err.to_string()),
            MessagingError::RateLimitExceeded(_) => {
                tonic::Status::resource_exhausted(err.to_string())
            }
            MessagingError::ProviderUnavailable(_) => {
                tonic::Status::unavailable(err.to_string())
            }
            _ => tonic::Status::internal(err.to_string()),
        }
    }
}
