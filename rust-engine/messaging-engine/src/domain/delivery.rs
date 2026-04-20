use chrono::{DateTime, Utc};
use uuid::Uuid;

use super::{message::MessageChannel, provider::Provider};

#[derive(Debug, Clone)]
pub struct DeliveryAttempt {
    pub message_id: Uuid,
    pub tenant_id: Uuid,
    pub recipient: String,
    pub channel: MessageChannel,
    pub body_preview: String,
    pub session_id: Option<String>,
    pub provider: Provider,
    pub status: DeliveryStatus,
    pub sent_at: Option<DateTime<Utc>>,
    pub delivered_at: Option<DateTime<Utc>>,
    pub provider_ref: Option<String>,
    pub error_message: Option<String>,
    pub retry_count: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryStatus {
    Queued,
    Sent,
    Delivered,
    Read,
    Failed,
    Rejected,
    Expired,
    Cancelled,
}

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: i32,
    pub initial_backoff_ms: i32,
    pub backoff_multiplier: f64,
    pub max_backoff_ms: i32,
    pub retry_on_timeout: bool,
}
