use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq)]
pub enum DomainError {
    #[error("Invalid phone number: {0}")]
    InvalidPhoneNumber(String),

    #[error("Invalid amount: {0}")]
    InvalidAmount(String),

    #[error("Invalid reference: {0}")]
    InvalidReference(String),

    #[error("Provider error: {0}")]
    ProviderError(String),

    #[error("Idempotency violation")]
    IdempotencyViolation,

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Invalid status transition from {from} to {to}")]
    InvalidStatusTransition { from: String, to: String },

    #[error("Database error: {0}")]
    DatabaseError(String),
}
