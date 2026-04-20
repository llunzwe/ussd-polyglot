use serde_json::json;
use std::sync::Arc;
use tracing::{info, warn};
use uuid::Uuid;

use crate::domain::error::DomainError;
use crate::domain::payment::Payment;
use crate::domain::provider::{ProviderClient, ProviderStatus};
use crate::infrastructure::outbox::OutboxRepository;
use crate::infrastructure::postgres::PgPaymentRepository;

#[derive(Debug, Clone)]
pub struct ProcessCallbackCommand {
    pub tenant_id: Uuid,
    pub provider_reference: String,
    pub payment_id: Option<Uuid>,
    pub status: ProviderStatus,
    pub signature: String,
    pub raw_payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct CallbackResult {
    pub payment: Payment,
    pub accepted: bool,
    pub new_status: String,
}

#[derive(Clone)]
pub struct ProcessCallbackHandler {
    payments: PgPaymentRepository,
    outbox: OutboxRepository,
    provider: Arc<dyn ProviderClient>,
}

impl std::fmt::Debug for ProcessCallbackHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProcessCallbackHandler")
            .field("payments", &self.payments)
            .field("outbox", &self.outbox)
            .field("provider", &"<dyn ProviderClient>")
            .finish()
    }
}

impl ProcessCallbackHandler {
    pub fn new(
        payments: PgPaymentRepository,
        outbox: OutboxRepository,
        provider: Arc<dyn ProviderClient>,
    ) -> Self {
        Self {
            payments,
            outbox,
            provider,
        }
    }

    pub async fn handle(&self, cmd: ProcessCallbackCommand) -> Result<CallbackResult, DomainError> {
        // 1. Verify HMAC signature
        if !self
            .provider
            .verify_callback_signature(&cmd.raw_payload, &cmd.signature)
        {
            warn!(
                provider_reference = %cmd.provider_reference,
                "Callback signature verification failed"
            );
            return Err(DomainError::ProviderError(
                "Invalid callback signature".to_string(),
            ));
        }

        // 2. Lookup payment by provider ref
        let mut payment = match self
            .payments
            .get_payment_by_provider_ref(Some(cmd.tenant_id), &cmd.provider_reference)
            .await?
        {
            Some(p) => p,
            None => {
                // Fallback: lookup by payment_id if provided
                if let Some(pid) = cmd.payment_id {
                    match self.payments.get_payment_by_id(cmd.tenant_id, pid).await? {
                        Some(p) => p,
                        None => {
                            return Err(DomainError::NotFound(format!(
                                "Payment with provider_reference {} not found",
                                cmd.provider_reference
                            )))
                        }
                    }
                } else {
                    return Err(DomainError::NotFound(format!(
                        "Payment with provider_reference {} not found",
                        cmd.provider_reference
                    )));
                }
            }
        };

        let previous_status = payment.status.clone();

        // 3. Update state based on provider status
        payment.apply_provider_status(cmd.status, Some(cmd.provider_reference.clone()));

        // 4. Persist updated payment
        self.payments.save_payment(&payment).await?;

        // 5. Append outbox event
        let event_type = match cmd.status {
            ProviderStatus::Completed => "PaymentCompleted",
            ProviderStatus::Failed => "PaymentFailed",
            ProviderStatus::Cancelled => "PaymentCancelled",
            ProviderStatus::Refunded => "PaymentRefunded",
            _ => "PaymentStatusUpdated",
        };

        let outbox_payload = json!({
            "event": event_type,
            "payment_id": payment.payment_id,
            "previous_status": previous_status.as_str(),
            "new_status": payment.status.as_str(),
            "provider_reference": cmd.provider_reference,
        });

        self.outbox
            .append_outbox(
                event_type,
                payment.payment_id,
                outbox_payload,
                &format!("{}-{}", cmd.provider_reference, event_type),
                payment.tenant_id,
            )
            .await?;

        info!(
            payment_id = %payment.payment_id,
            previous_status = %previous_status,
            new_status = %payment.status,
            "Payment callback processed"
        );

        Ok(CallbackResult {
            payment: payment.clone(),
            accepted: true,
            new_status: payment.status.as_str().to_string(),
        })
    }
}
