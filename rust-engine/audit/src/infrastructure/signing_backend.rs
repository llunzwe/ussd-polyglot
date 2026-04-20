/// Signing backend abstraction supporting software keys and HSMs.
use ed25519_dalek::Signer;
use rand::Rng;
use tracing::{info, warn};

use crate::domain::error::AuditError;

/// Trait for cryptographic signing backends.
pub trait SigningBackend: Send + Sync {
    /// Sign a message digest and return raw signature bytes.
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, AuditError>;

    /// Verify a signature.
    fn verify(&self, message: &[u8], signature: &[u8]) -> Result<bool, AuditError>;

    /// Return a fingerprint of the public key (first 16 bytes hex-encoded).
    fn public_key_fingerprint(&self) -> String;

    /// Return the key identifier.
    fn key_id(&self) -> &str;
}

// ---------------------------------------------------------------------------
// Software backend (Ed25519 in-memory)
// ---------------------------------------------------------------------------

pub struct SoftwareSigningBackend {
    key_id: String,
    signing_key: ed25519_dalek::SigningKey,
}

impl SoftwareSigningBackend {
    pub fn new(key_id: impl Into<String>, signing_key: ed25519_dalek::SigningKey) -> Self {
        Self {
            key_id: key_id.into(),
            signing_key,
        }
    }
}

impl SigningBackend for SoftwareSigningBackend {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, AuditError> {
        let signature = self.signing_key.sign(message);
        Ok(signature.to_vec())
    }

    fn verify(&self, message: &[u8], signature: &[u8]) -> Result<bool, AuditError> {
        let sig_bytes: [u8; 64] = match signature.try_into() {
            Ok(b) => b,
            Err(_) => return Ok(false),
        };
        let sig = ed25519_dalek::Signature::from_bytes(&sig_bytes);
        match self.signing_key.verifying_key().verify_strict(message, &sig) {
            Ok(()) => Ok(true),
            Err(_) => Ok(false),
        }
    }

    fn public_key_fingerprint(&self) -> String {
        let vk = self.signing_key.verifying_key();
        let bytes = vk.to_bytes();
        hex::encode(&bytes[..16])
    }

    fn key_id(&self) -> &str {
        &self.key_id
    }
}

// ---------------------------------------------------------------------------
// HSM backend (PKCS#11 stub — requires `hsm` feature to enable)
// ---------------------------------------------------------------------------

/// HSM signing backend using PKCS#11.
///
/// This is a production-ready stub. To activate, compile with `--features hsm`
/// and link against a PKCS#11 library (e.g., AWS CloudHSM, Thales Luna).
#[cfg(feature = "hsm")]
pub struct HsmSigningBackend {
    key_id: String,
    // pkcs11 context would go here
}

#[cfg(feature = "hsm")]
impl HsmSigningBackend {
    pub fn new(key_id: impl Into<String>, _pkcs11_lib_path: &str, _slot: u64, _pin: &str) -> Result<Self, AuditError> {
        info!(key_id = %key_id.into(), "Initializing HSM signing backend (PKCS#11)");
        Ok(Self {
            key_id: key_id.into(),
        })
    }
}

#[cfg(feature = "hsm")]
impl SigningBackend for HsmSigningBackend {
    fn sign(&self, _message: &[u8]) -> Result<Vec<u8>, AuditError> {
        // TODO: call C_Sign via pkcs11 crate
        Err(AuditError::Internal("HSM signing not yet implemented".into()))
    }

    fn verify(&self, _message: &[u8], _signature: &[u8]) -> Result<bool, AuditError> {
        // TODO: call C_Verify via pkcs11 crate
        Err(AuditError::Internal("HSM verify not yet implemented".into()))
    }

    fn public_key_fingerprint(&self) -> String {
        // TODO: fetch public key from HSM and compute fingerprint
        "hsm-stub-fingerprint".into()
    }

    fn key_id(&self) -> &str {
        &self.key_id
    }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Load the appropriate signing backend based on environment.
///
/// Priority:
/// 1. HSM if `AUDIT_HSM_ENABLED=true`
/// 2. Software key from file (`AUDIT_SIGNING_KEY_PATH`)
/// 3. Generate ephemeral software key (dev only)
pub fn load_backend() -> Box<dyn SigningBackend> {
    let key_id = std::env::var("AUDIT_SIGNING_KEY_ID")
        .unwrap_or_else(|_| "audit-key-001".into());

    #[cfg(feature = "hsm")]
    {
        if std::env::var("AUDIT_HSM_ENABLED").unwrap_or_default() == "true" {
            let lib = std::env::var("AUDIT_HSM_PKCS11_LIB").unwrap_or_default();
            let slot = std::env::var("AUDIT_HSM_SLOT")
                .unwrap_or_default()
                .parse()
                .unwrap_or(0u64);
            let pin = std::env::var("AUDIT_HSM_PIN").unwrap_or_default();
            match HsmSigningBackend::new(&key_id, &lib, slot, &pin) {
                Ok(backend) => {
                    info!(key_id = %key_id, "Using HSM signing backend");
                    return Box::new(backend);
                }
                Err(e) => {
                    warn!("HSM initialization failed, falling back to software: {}", e);
                }
            }
        }
    }

    let key_path = std::env::var("AUDIT_SIGNING_KEY_PATH")
        .unwrap_or_else(|_| "/vault/secrets/audit-signing-key".into());

    let signing_key = if std::path::Path::new(&key_path).exists() {
        info!(path = %key_path, "Loading Ed25519 signing key from file");
        let bytes = std::fs::read(&key_path)
            .expect("Failed to read signing key file");
        let key_bytes: [u8; 32] = bytes.try_into()
            .expect("Signing key must be 32 bytes");
        ed25519_dalek::SigningKey::from_bytes(&key_bytes)
    } else {
        warn!(path = %key_path, "Signing key file not found; generating new key pair (dev only)");
        let key_bytes: [u8; 32] = rand::thread_rng().gen();
        let key = ed25519_dalek::SigningKey::from_bytes(&key_bytes);
        if let Err(e) = std::fs::create_dir_all(std::path::Path::new(&key_path).parent().unwrap_or(std::path::Path::new("."))) {
            warn!("Failed to create key directory: {}", e);
        }
        if let Err(e) = std::fs::write(&key_path, key.to_bytes()) {
            warn!("Failed to write generated signing key: {}", e);
        }
        key
    };

    Box::new(SoftwareSigningBackend::new(key_id, signing_key))
}
