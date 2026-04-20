use async_trait::async_trait;

use crate::domain::{delivery::DeliveryStatus, error::MessagingError, provider::ProviderReceipt};

#[async_trait]
pub trait SmsProviderPort: Send + Sync {
    async fn send_sms(
        &self,
        to: &str,
        body: &str,
        sender_id: &str,
    ) -> Result<ProviderReceipt, MessagingError>;
    async fn get_status(&self, provider_ref: &str) -> Result<DeliveryStatus, MessagingError>;
    fn provider_name(&self) -> &'static str;
}
