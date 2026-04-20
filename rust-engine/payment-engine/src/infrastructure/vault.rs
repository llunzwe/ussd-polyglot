use async_trait::async_trait;
use serde::Deserialize;
use std::env;

#[derive(Debug, Clone)]
pub struct ProviderCredentials {
    pub base_url: String,
    pub merchant_id: String,
    pub api_key: String,
    pub secret_key: String,
}

#[async_trait]
pub trait VaultClient: Send + Sync {
    async fn get_credentials(&self, provider: &str) -> Result<ProviderCredentials, String>;
}

#[derive(Debug, Clone)]
pub struct MockVaultClient;

#[async_trait]
impl VaultClient for MockVaultClient {
    async fn get_credentials(&self, provider: &str) -> Result<ProviderCredentials, String> {
        let prefix = provider.to_uppercase();
        Ok(ProviderCredentials {
            base_url: env::var(format!("{}_BASE_URL", prefix))
                .unwrap_or_else(|_| "https://api.example.com".to_string()),
            merchant_id: env::var(format!("{}_MERCHANT_ID", prefix)).unwrap_or_default(),
            api_key: env::var(format!("{}_API_KEY", prefix)).unwrap_or_default(),
            secret_key: env::var(format!("{}_SECRET_KEY", prefix)).unwrap_or_default(),
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
struct VaultKv2Data {
    data: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
struct VaultKv2Response {
    data: VaultKv2Data,
}

#[derive(Debug, Clone)]
pub struct HttpVaultClient {
    base_url: String,
    token: String,
    http: reqwest::Client,
}

impl HttpVaultClient {
    pub async fn login(role_id: &str, secret_id: &str) -> Result<String, String> {
        let client = reqwest::Client::new();
        let vault_addr = env::var("VAULT_ADDR").unwrap_or_else(|_| "http://127.0.0.1:8200".to_string());
        let url = format!("{}/v1/auth/approle/login", vault_addr);

        let body = serde_json::json!({
            "role_id": role_id,
            "secret_id": secret_id,
        });

        let resp = client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("vault login request failed: {}", e))?
            .error_for_status()
            .map_err(|e| format!("vault login returned error: {}", e))?
            .json::<serde_json::Value>()
            .await
            .map_err(|e| format!("failed to parse vault login response: {}", e))?;

        resp["auth"]["client_token"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| "missing client_token in vault login response".to_string())
    }

    pub fn new(token: String) -> Self {
        let base_url = env::var("VAULT_ADDR").unwrap_or_else(|_| "http://127.0.0.1:8200".to_string());
        Self {
            base_url,
            token,
            http: reqwest::Client::new(),
        }
    }

    pub async fn read_secret(&self, path: &str) -> Result<serde_json::Value, String> {
        let url = format!("{}/v1/secret/data/{}", self.base_url, path);
        let resp = self
            .http
            .get(&url)
            .header("X-Vault-Token", &self.token)
            .send()
            .await
            .map_err(|e| format!("vault read request failed: {}", e))?
            .error_for_status()
            .map_err(|e| format!("vault read returned error: {}", e))?
            .json::<VaultKv2Response>()
            .await
            .map_err(|e| format!("failed to parse vault read response: {}", e))?;

        Ok(resp.data.data)
    }
}

#[async_trait]
impl VaultClient for HttpVaultClient {
    async fn get_credentials(&self, provider: &str) -> Result<ProviderCredentials, String> {
        let path = format!("ussd-kernel/providers/{}", provider);
        let secret = self.read_secret(&path).await?;

        let base_url = secret["base_url"]
            .as_str()
            .unwrap_or("https://api.example.com")
            .to_string();
        let merchant_id = secret["merchant_id"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let api_key = secret["api_key"].as_str().unwrap_or_default().to_string();
        let secret_key = secret["secret_key"].as_str().unwrap_or_default().to_string();

        Ok(ProviderCredentials {
            base_url,
            merchant_id,
            api_key,
            secret_key,
        })
    }
}

/// Returns a real Vault client if `VAULT_ROLE_ID` and `VAULT_SECRET_ID` are set,
/// otherwise falls back to the mock implementation.
pub async fn get_vault_client() -> Result<Box<dyn VaultClient>, String> {
    let role_id = env::var("VAULT_ROLE_ID").unwrap_or_default();
    let secret_id = env::var("VAULT_SECRET_ID").unwrap_or_default();

    if role_id.is_empty() || secret_id.is_empty() {
        return Ok(Box::new(MockVaultClient));
    }

    let token = HttpVaultClient::login(&role_id, &secret_id).await?;
    Ok(Box::new(HttpVaultClient::new(token)))
}
