//! Retry policy use-case.
use crate::domain::delivery::RetryPolicy;

/// Default retry policy for messaging delivery.
pub fn default_retry_policy() -> RetryPolicy {
    RetryPolicy {
        max_retries: 3,
        initial_backoff_ms: 500,
        backoff_multiplier: 2.0,
        max_backoff_ms: 30_000,
        retry_on_timeout: true,
    }
}
