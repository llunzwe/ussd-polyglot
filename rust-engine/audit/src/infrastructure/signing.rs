use tracing::info;

use crate::domain::error::AuditError;
use crate::infrastructure::signing_backend::{load_backend, SigningBackend};

/// Ed25519 signing service for audit batch hashes.
/// Delegates to a `SigningBackend` (software or HSM).
#[derive(Clone)]
pub struct SigningService {
    backend: std::sync::Arc<dyn SigningBackend>,
}

impl SigningService {
    pub fn new(backend: Box<dyn SigningBackend>) -> Self {
        Self {
            backend: std::sync::Arc::from(backend),
        }
    }

    /// Sign a batch hash, returning signature bytes + public key fingerprint.
    pub fn sign_batch_hash(&self, batch_hash: &str) -> Result<(Vec<u8>, String), AuditError> {
        let signature = self.backend.sign(batch_hash.as_bytes())?;
        let fingerprint = self.backend.public_key_fingerprint();
        info!(key_id = %self.backend.key_id(), fingerprint = %fingerprint, "Signed batch hash with Ed25519");
        Ok((signature, fingerprint))
    }

    /// Verify a batch hash signature.
    pub fn verify_batch_hash(&self, batch_hash: &str, signature: &[u8]) -> Result<bool, AuditError> {
        self.backend.verify(batch_hash.as_bytes(), signature)
    }

    pub fn key_id(&self) -> &str {
        self.backend.key_id()
    }

    pub fn public_key_fingerprint(&self) -> String {
        self.backend.public_key_fingerprint()
    }
}

/// Load the active signing key from the configured backend.
pub fn load_signing_key() -> SigningService {
    let backend = load_backend();
    info!(key_id = %backend.key_id(), backend_type = %std::any::type_name_of_val(&*backend), "Signing backend loaded");
    SigningService::new(backend)
}
