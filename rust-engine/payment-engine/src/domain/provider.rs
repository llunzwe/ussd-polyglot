use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::domain::error::DomainError;
use crate::domain::payment::Payment;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MobileMoneyProvider {
    EcoCash,
    OneMoney,
    Telecash,
}

impl MobileMoneyProvider {
    pub fn as_str(&self) -> &'static str {
        match self {
            MobileMoneyProvider::EcoCash => "ecocash",
            MobileMoneyProvider::OneMoney => "onemoney",
            MobileMoneyProvider::Telecash => "telecash",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderResponse {
    pub provider_reference: String,
    pub status: ProviderStatus,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProviderStatus {
    Pending,
    Processing,
    Completed,
    Failed,
    Cancelled,
    Refunded,
    Unknown,
}

impl ProviderStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProviderStatus::Pending => "pending",
            ProviderStatus::Processing => "processing",
            ProviderStatus::Completed => "completed",
            ProviderStatus::Failed => "failed",
            ProviderStatus::Cancelled => "cancelled",
            ProviderStatus::Refunded => "refunded",
            ProviderStatus::Unknown => "unknown",
        }
    }
}

#[async_trait]
pub trait ProviderClient: Send + Sync {
    async fn initiate(&self, payment: &Payment) -> Result<ProviderResponse, DomainError>;
    async fn check_status(&self, provider_ref: &str) -> Result<ProviderStatus, DomainError>;
    fn verify_callback_signature(&self, payload: &[u8], signature: &str) -> bool;
}
