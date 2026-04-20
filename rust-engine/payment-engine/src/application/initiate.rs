use rand::Rng;
use rust_decimal::Decimal;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::domain::error::DomainError;
use crate::domain::payment::Payment;
use crate::domain::provider::{MobileMoneyProvider, ProviderClient, ProviderResponse};
use crate::infrastructure::outbox::OutboxRepository;
use crate::infrastructure::postgres::PgPaymentRepository;

#[derive(Debug, Clone)]
pub struct InitiatePaymentCommand {
    pub payment_id: Uuid,
    pub tenant_id: Uuid,
    pub idempotency_key: String,
    pub provider: MobileMoneyProvider,
    pub phone_number: String,
    pub amount: Decimal,
    pub currency: String,
    pub reference: String,
    pub description: String,
}

#[derive(Debug, Clone)]
pub struct InitiateResult {
    pub payment: Payment,
    pub provider_reference: Option<String>,
}

#[derive(Clone)]
pub struct InitiatePaymentHandler {
    payments: PgPaymentRepository,
    outbox: OutboxRepository,
    provider: Arc<dyn ProviderClient>,
}

impl std::fmt::Debug for InitiatePaymentHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InitiatePaymentHandler")
            .field("payments", &self.payments)
            .field("outbox", &self.outbox)
            .field("provider", &"<dyn ProviderClient>")
            .finish()
    }
}

impl InitiatePaymentHandler {
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

    pub async fn handle(&self, cmd: InitiatePaymentCommand) -> Result<InitiateResult, DomainError> {
        // 1. Idempotency check
        if let Some(existing) = self
            .payments
            .find_by_idempotency_key(cmd.tenant_id, &cmd.idempotency_key)
            .await?
        {
            warn!(
                payment_id = %existing.payment_id,
                idempotency_key = %cmd.idempotency_key,
                "Idempotency key already exists"
            );
            return Err(DomainError::IdempotencyViolation);
        }

        // 2. Create and validate payment
        let mut payment = Payment::new(
            cmd.payment_id,
            cmd.tenant_id,
            cmd.idempotency_key.clone(),
            cmd.provider,
            cmd.phone_number,
            cmd.amount,
            cmd.currency,
            cmd.reference,
            cmd.description,
        )?;

        // 3. Persist initial pending state
        self.payments.save_payment(&payment).await?;

        // 4. Call provider with retry
        let provider_result = self
            .call_provider_with_retry(&payment)
            .await;

        match provider_result {
            Ok(response) => {
                payment.mark_processing()?;
                payment.provider_reference = Some(response.provider_reference.clone());

                // Save updated state
                self.payments.save_payment(&payment).await?;

                // Append outbox event
                let outbox_payload = json!({
                    "event": "PaymentInitiated",
                    "payment_id": payment.payment_id,
                    "provider_reference": response.provider_reference,
                    "status": payment.status.as_str(),
                });
                self.outbox
                    .append_outbox(
                        "PaymentInitiated",
                        payment.payment_id,
                        outbox_payload,
                        &format!("{}-initiated", cmd.idempotency_key),
                        payment.tenant_id,
                    )
                    .await?;

                info!(
                    payment_id = %payment.payment_id,
                    provider_reference = %response.provider_reference,
                    "Payment initiated successfully"
                );

                Ok(InitiateResult {
                    payment,
                    provider_reference: Some(response.provider_reference),
                })
            }
            Err(e) => {
                payment.mark_failed(e.to_string()).ok();
                self.payments.save_payment(&payment).await?;

                let outbox_payload = json!({
                    "event": "PaymentFailed",
                    "payment_id": payment.payment_id,
                    "reason": e.to_string(),
                    "status": payment.status.as_str(),
                });
                self.outbox
                    .append_outbox(
                        "PaymentFailed",
                        payment.payment_id,
                        outbox_payload,
                        &format!("{}-failed", cmd.idempotency_key),
                        payment.tenant_id,
                    )
                    .await
                    .ok();

                error!(
                    payment_id = %payment.payment_id,
                    error = %e,
                    "Payment initiation failed"
                );
                Err(e)
            }
        }
    }

    async fn call_provider_with_retry(
        &self,
        payment: &Payment,
    ) -> Result<ProviderResponse, DomainError> {
        let max_attempts = 3;
        let mut last_error = None;

        for attempt in 0..max_attempts {
            match self.provider.initiate(payment).await {
                Ok(response) => return Ok(response),
                Err(e) => {
                    warn!(
                        payment_id = %payment.payment_id,
                        attempt = attempt + 1,
                        error = %e,
                        "Provider initiate attempt failed"
                    );
                    last_error = Some(e);
                    if attempt < max_attempts - 1 {
                        let backoff = Duration::from_secs(2u64.pow(attempt as u32));
                        let jitter = rand::thread_rng().gen_range(0..500);
                        sleep(backoff + Duration::from_millis(jitter)).await;
                    }
                }
            }
        }

        Err(last_error.unwrap_or_else(|| {
            DomainError::ProviderError("Unknown provider error after retries".to_string())
        }))
    }
}
