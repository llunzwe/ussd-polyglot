use std::fs;

use tonic::transport::{Certificate, Channel, ClientTlsConfig, Identity, ServerTlsConfig};

/// Load server TLS configuration with mutual TLS (mTLS).
pub fn load_server_tls_config(
    cert_path: &str,
    key_path: &str,
    ca_path: &str,
) -> Result<ServerTlsConfig, Box<dyn std::error::Error>> {
    let cert = fs::read(cert_path)?;
    let key = fs::read(key_path)?;
    let ca = fs::read(ca_path)?;

    let identity = Identity::from_pem(cert, key);
    let client_ca = Certificate::from_pem(ca);

    Ok(ServerTlsConfig::new()
        .identity(identity)
        .client_ca_root(client_ca))
}

/// Load client TLS configuration with mutual TLS (mTLS) and return a connected Channel.
pub async fn load_client_tls_config(
    cert_path: &str,
    key_path: &str,
    ca_path: &str,
    target: &str,
) -> Result<Channel, Box<dyn std::error::Error>> {
    let cert = fs::read(cert_path)?;
    let key = fs::read(key_path)?;
    let ca = fs::read(ca_path)?;

    let identity = Identity::from_pem(cert, key);
    let ca_cert = Certificate::from_pem(ca);

    let tls_config = ClientTlsConfig::new().identity(identity).ca_certificate(ca_cert);
    let channel = Channel::from_shared(target.to_string())?
        .tls_config(tls_config)?
        .connect()
        .await?;

    Ok(channel)
}
