use async_trait::async_trait;
use hmac::{Hmac, Mac};
use reqwest::Client;
use sha2::Sha256;
use tracing::{info, instrument};

use crate::domain::delivery::DeliveryStatus;
use crate::domain::error::MessagingError;
use crate::domain::provider::ProviderReceipt;
use crate::ports::sms_provider::SmsProviderPort;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub struct EcoCashAdapter {
    client: Client,
    base_url: String,
    api_key: String,
    api_secret: String,
}

impl EcoCashAdapter {
    pub fn new(base_url: String, api_key: String, api_secret: String) -> Self {
        Self {
            client: Client::new(),
            base_url,
            api_key,
            api_secret,
        }
    }

    fn sign_payload(&self, payload: &str) -> String {
        let mut mac =
            HmacSha256::new_from_slice(self.api_secret.as_bytes()).expect("HMAC accepts any key");
        mac.update(payload.as_bytes());
        let result = mac.finalize();
        hex::encode(result.into_bytes())
    }
}

#[async_trait]
impl SmsProviderPort for EcoCashAdapter {
    #[instrument(skip(self))]
    async fn send_sms(
        &self,
        to: &str,
        body: &str,
        sender_id: &str,
    ) -> Result<ProviderReceipt, MessagingError> {
        let payload = format!("to={}&body={}&sender={}", to, body, sender_id);
        let signature = self.sign_payload(&payload);

        info!(
            recipient = %to,
            signature_prefix = %&signature[..8.min(signature.len())],
            "EcoCash send_sms stub"
        );

        let _ = self.client;
        let _ = self.base_url;
        let _ = self.api_key;

        Ok(ProviderReceipt {
            provider_ref: format!("ECO-{}", uuid::Uuid::new_v4()),
            raw_response: r#"{"status":"accepted","message_id":"stub"}"#.to_string(),
        })
    }

    #[instrument(skip(self))]
    async fn get_status(&self, provider_ref: &str) -> Result<DeliveryStatus, MessagingError> {
        info!(provider_ref = %provider_ref, "EcoCash get_status stub");
        Ok(DeliveryStatus::Delivered)
    }

    fn provider_name(&self) -> &'static str {
        "ecocash"
    }
}
