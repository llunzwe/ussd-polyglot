use async_trait::async_trait;
use hmac::{Hmac, Mac};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::time::Duration;
use tracing::{error, info};

use crate::domain::error::DomainError;
use crate::domain::payment::Payment;
use crate::domain::provider::{ProviderClient, ProviderResponse, ProviderStatus};
use crate::infrastructure::vault::ProviderCredentials;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct EcoCashClient {
    client: Client,
    credentials: ProviderCredentials,
}

#[derive(Debug, Serialize)]
struct EcoCashInitiateRequest {
    merchant_id: String,
    phone_number: String,
    amount: String,
    currency: String,
    reference: String,
    description: String,
    callback_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EcoCashInitiateResponse {
    provider_reference: String,
    status: String,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EcoCashStatusResponse {
    status: String,
    #[allow(dead_code)]
    message: Option<String>,
}

impl EcoCashClient {
    pub fn new(credentials: ProviderCredentials) -> Self {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to build reqwest client");

        Self {
            client,
            credentials,
        }
    }

    pub fn generate_signature(&self, payload: &[u8]) -> String {
        let mut mac = HmacSha256::new_from_slice(self.credentials.secret_key.as_bytes())
            .expect("HMAC can take key of any size");
        mac.update(payload);
        let result = mac.finalize();
        hex::encode(result.into_bytes())
    }
}

#[async_trait]
impl ProviderClient for EcoCashClient {
    async fn initiate(&self, payment: &Payment) -> Result<ProviderResponse, DomainError> {
        let url = format!("{}/v1/payments/initiate", self.credentials.base_url);
        let body = EcoCashInitiateRequest {
            merchant_id: self.credentials.merchant_id.clone(),
            phone_number: payment.phone_number.clone(),
            amount: payment.amount.to_string(),
            currency: payment.currency.clone(),
            reference: payment.reference.clone(),
            description: payment.description.clone(),
            callback_url: None,
        };

        let payload = serde_json::to_vec(&body)
            .map_err(|e| DomainError::ProviderError(e.to_string()))?;
        let signature = self.generate_signature(&payload);

        info!(
            payment_id = %payment.payment_id,
            provider = "ecocash",
            "Initiating payment with EcoCash"
        );

        let response = self
            .client
            .post(&url)
            .header("X-Api-Key", &self.credentials.api_key)
            .header("X-Signature", &signature)
            .header("Content-Type", "application/json")
            .body(payload)
            .send()
            .await
            .map_err(|e| {
                error!(error = %e, "EcoCash initiate request failed");
                DomainError::ProviderError(e.to_string())
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            error!(status = %status, body = %text, "EcoCash initiate returned error");
            return Err(DomainError::ProviderError(format!(
                "EcoCash error {}: {}",
                status, text
            )));
        }

        let parsed: EcoCashInitiateResponse = response.json().await.map_err(|e| {
            error!(error = %e, "Failed to parse EcoCash initiate response");
            DomainError::ProviderError(e.to_string())
        })?;

        let status = parse_provider_status(&parsed.status);

        Ok(ProviderResponse {
            provider_reference: parsed.provider_reference,
            status,
            message: parsed.message,
        })
    }

    async fn check_status(&self, provider_ref: &str) -> Result<ProviderStatus, DomainError> {
        let url = format!(
            "{}/v1/payments/{}/status",
            self.credentials.base_url, provider_ref
        );

        let response = self
            .client
            .get(&url)
            .header("X-Api-Key", &self.credentials.api_key)
            .send()
            .await
            .map_err(|e| DomainError::ProviderError(e.to_string()))?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(DomainError::ProviderError(format!(
                "EcoCash status error {}: {}",
                status, text
            )));
        }

        let parsed: EcoCashStatusResponse = response.json().await.map_err(|e| {
            DomainError::ProviderError(format!("Failed to parse status response: {}", e))
        })?;

        Ok(parse_provider_status(&parsed.status))
    }

    fn verify_callback_signature(&self, payload: &[u8], signature: &str) -> bool {
        let expected = self.generate_signature(payload);
        use std::cmp::Ordering;
        signature.len().cmp(&expected.len()) == Ordering::Equal
            && constant_time_eq::constant_time_eq(signature.as_bytes(), expected.as_bytes())
    }
}

fn parse_provider_status(status: &str) -> ProviderStatus {
    match status.to_lowercase().as_str() {
        "pending" => ProviderStatus::Pending,
        "processing" => ProviderStatus::Processing,
        "completed" | "success" => ProviderStatus::Completed,
        "failed" | "failure" => ProviderStatus::Failed,
        "cancelled" => ProviderStatus::Cancelled,
        "refunded" => ProviderStatus::Refunded,
        _ => ProviderStatus::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_signature() {
        let creds = ProviderCredentials {
            base_url: "https://api.ecocash.test".to_string(),
            merchant_id: "MERCH-001".to_string(),
            api_key: "api-key-123".to_string(),
            secret_key: "super-secret-key".to_string(),
        };
        let client = EcoCashClient::new(creds);
        let payload = b"test-payload";
        let sig1 = client.generate_signature(payload);
        let sig2 = client.generate_signature(payload);
        assert_eq!(sig1, sig2);
        assert_eq!(sig1.len(), 64); // SHA-256 hex is 64 chars
    }

    #[test]
    fn test_signature_changes_with_payload() {
        let creds = ProviderCredentials {
            base_url: "https://api.ecocash.test".to_string(),
            merchant_id: "MERCH-001".to_string(),
            api_key: "api-key-123".to_string(),
            secret_key: "super-secret-key".to_string(),
        };
        let client = EcoCashClient::new(creds);
        let sig1 = client.generate_signature(b"payload-a");
        let sig2 = client.generate_signature(b"payload-b");
        assert_ne!(sig1, sig2);
    }
}
