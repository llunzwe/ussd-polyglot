use async_trait::async_trait;
use reqwest::Client;
use tracing::{info, instrument};

use crate::domain::delivery::DeliveryStatus;
use crate::domain::error::MessagingError;
use crate::domain::provider::ProviderReceipt;
use crate::ports::sms_provider::SmsProviderPort;

#[derive(Clone)]
pub struct TeleCashAdapter {
    client: Client,
    base_url: String,
    bearer_token: String,
}

impl TeleCashAdapter {
    pub fn new(base_url: String, bearer_token: String) -> Self {
        Self {
            client: Client::new(),
            base_url,
            bearer_token,
        }
    }
}

#[async_trait]
impl SmsProviderPort for TeleCashAdapter {
    #[instrument(skip(self))]
    async fn send_sms(
        &self,
        to: &str,
        body: &str,
        _sender_id: &str,
    ) -> Result<ProviderReceipt, MessagingError> {
        info!(
            recipient = %to,
            body_len = body.len(),
            "TeleCash send_sms REST stub"
        );

        let _ = self.client;
        let _ = self.base_url;
        let _ = self.bearer_token;

        Ok(ProviderReceipt {
            provider_ref: format!("TC-{}", uuid::Uuid::new_v4()),
            raw_response: r#"{"status":"queued","message_id":"stub"}"#.to_string(),
        })
    }

    #[instrument(skip(self))]
    async fn get_status(&self, provider_ref: &str) -> Result<DeliveryStatus, MessagingError> {
        info!(provider_ref = %provider_ref, "TeleCash get_status stub");
        Ok(DeliveryStatus::Sent)
    }

    fn provider_name(&self) -> &'static str {
        "telecash"
    }
}
