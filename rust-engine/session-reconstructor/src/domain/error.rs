use thiserror::Error;

#[derive(Debug, Error)]
pub enum DomainError {
    #[error("session not found")]
    SessionNotFound,

    #[error("event sequence gap: expected {expected}, found {found}")]
    EventSequenceGap { expected: i64, found: i64 },

    #[error("hash mismatch at version {version}")]
    HashMismatch { version: i64 },

    #[error("invalid event type: {0}")]
    InvalidEventType(String),

    #[error("internal error: {0}")]
    Internal(String),
}
