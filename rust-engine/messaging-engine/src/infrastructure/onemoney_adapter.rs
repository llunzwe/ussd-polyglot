use async_trait::async_trait;
use reqwest::Client;
use tracing::{info, instrument};

use crate::domain::delivery::DeliveryStatus;
use crate::domain::error::MessagingError;
use crate::domain::provider::ProviderReceipt;
use crate::ports::sms_provider::SmsProviderPort;

#[derive(Clone)]
pub struct OneMoneyAdapter {
    client: Client,
    base_url: String,
    username: String,
    password: String,
}

impl OneMoneyAdapter {
    pub fn new(base_url: String, username: String, password: String) -> Self {
        Self {
            client: Client::new(),
            base_url,
            username,
            password,
        }
    }
}

#[async_trait]
impl SmsProviderPort for OneMoneyAdapter {
    #[instrument(skip(self))]
    async fn send_sms(
        &self,
        to: &str,
        body: &str,
        _sender_id: &str,
    ) -> Result<ProviderReceipt, MessagingError> {
        let _soap_body = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <SendSMS>
      <To>{}</To>
      <Body>{}</Body>
      <Username>{}</Username>
    </SendSMS>
  </soap:Body>
</soap:Envelope>"#,
            to, body, self.username
        );

        info!(
            recipient = %to,
            body_len = body.len(),
            "OneMoney send_sms SOAP stub"
        );

        let _ = self.client;
        let _ = self.base_url;
        let _ = self.password;

        Ok(ProviderReceipt {
            provider_ref: format!("OM-{}", uuid::Uuid::new_v4()),
            raw_response: r#"<?xml version="1.0"?><Response><Status>OK</Status></Response>"#
                .to_string(),
        })
    }

    #[instrument(skip(self))]
    async fn get_status(&self, provider_ref: &str) -> Result<DeliveryStatus, MessagingError> {
        info!(provider_ref = %provider_ref, "OneMoney get_status stub");
        Ok(DeliveryStatus::Delivered)
    }

    fn provider_name(&self) -> &'static str {
        "onemoney"
    }
}
