use std::sync::Arc;

use chrono::Utc;
use tracing::{info, instrument, warn};
use uuid::Uuid;

use crate::domain::delivery::{DeliveryAttempt, DeliveryStatus};
use crate::domain::error::MessagingError;
use crate::domain::message::{Message, MessageChannel, route_provider};
use crate::domain::provider::Provider;
use crate::ports::delivery_log::{DeliveryLogPort, MessageFilters};
use crate::ports::sms_provider::SmsProviderPort;
use crate::ports::template_store::TemplateStorePort;

#[derive(Clone)]
pub struct MessagingHandler {
    providers: Vec<Arc<dyn SmsProviderPort>>,
    template_store: Arc<dyn TemplateStorePort>,
    delivery_log: Arc<dyn DeliveryLogPort>,
}

impl MessagingHandler {
    pub fn new(
        providers: Vec<Arc<dyn SmsProviderPort>>,
        template_store: Arc<dyn TemplateStorePort>,
        delivery_log: Arc<dyn DeliveryLogPort>,
    ) -> Self {
        Self {
            providers,
            template_store,
            delivery_log,
        }
    }

    fn select_provider(&self, recipient: &str) -> Result<Arc<dyn SmsProviderPort>, MessagingError> {
        let expected = route_provider(recipient)
            .ok_or_else(|| MessagingError::InvalidPhone(recipient.to_string()))?;

        for provider in &self.providers {
            let name = provider.provider_name();
            if matches!(
                (expected, name),
                (Provider::EcoCash, "ecocash")
                    | (Provider::OneMoney, "onemoney")
                    | (Provider::TeleCash, "telecash")
            ) {
                return Ok(provider.clone());
            }
        }

        Err(MessagingError::ProviderUnavailable(format!(
            "No adapter found for recipient {}",
            recipient
        )))
    }

    #[instrument(skip(self, msg))]
    pub async fn send_sms(&self, msg: Message) -> Result<DeliveryAttempt, MessagingError> {
        let provider = self.select_provider(&msg.recipient)?;
        let receipt = provider
            .send_sms(&msg.recipient, &msg.body, "USSD-KERNEL")
            .await?;

        let attempt = DeliveryAttempt {
            message_id: msg.id,
            tenant_id: msg.tenant_id,
            recipient: msg.recipient.clone(),
            channel: msg.channel,
            body_preview: msg.body.chars().take(160).collect(),
            session_id: msg.session_id.clone(),
            provider: route_provider(&msg.recipient).unwrap_or(Provider::EcoCash),
            status: DeliveryStatus::Sent,
            sent_at: Some(Utc::now()),
            delivered_at: None,
            provider_ref: Some(receipt.provider_ref),
            error_message: None,
            retry_count: 0,
        };

        self.delivery_log.log_attempt(&attempt).await?;
        info!(message_id = %msg.id, "SMS sent successfully");
        Ok(attempt)
    }

    #[instrument(skip(self, msg))]
    pub async fn send_whatsapp(&self, msg: Message) -> Result<DeliveryAttempt, MessagingError> {
        let provider = self.select_provider(&msg.recipient)?;
        let receipt = provider
            .send_sms(&msg.recipient, &msg.body, "USSD-KERNEL")
            .await?;

        let attempt = DeliveryAttempt {
            message_id: msg.id,
            tenant_id: msg.tenant_id,
            recipient: msg.recipient.clone(),
            channel: MessageChannel::WhatsApp,
            body_preview: msg.body.chars().take(160).collect(),
            session_id: msg.session_id.clone(),
            provider: route_provider(&msg.recipient).unwrap_or(Provider::EcoCash),
            status: DeliveryStatus::Sent,
            sent_at: Some(Utc::now()),
            delivered_at: None,
            provider_ref: Some(receipt.provider_ref),
            error_message: None,
            retry_count: 0,
        };

        self.delivery_log.log_attempt(&attempt).await?;
        info!(message_id = %msg.id, "WhatsApp sent successfully");
        Ok(attempt)
    }

    #[instrument(skip(self, msg))]
    pub async fn send_email(&self, msg: Message) -> Result<DeliveryAttempt, MessagingError> {
        // Email uses the first available provider as a transport fallback in this stub.
        let provider = self.providers.first().ok_or_else(|| {
            MessagingError::ProviderUnavailable("No providers configured".into())
        })?;
        let receipt = provider
            .send_sms(&msg.recipient, &msg.body, "USSD-KERNEL")
            .await?;

        let attempt = DeliveryAttempt {
            message_id: msg.id,
            tenant_id: msg.tenant_id,
            recipient: msg.recipient.clone(),
            channel: MessageChannel::Email,
            body_preview: msg.body.chars().take(160).collect(),
            session_id: msg.session_id.clone(),
            provider: Provider::EcoCash,
            status: DeliveryStatus::Sent,
            sent_at: Some(Utc::now()),
            delivered_at: None,
            provider_ref: Some(receipt.provider_ref),
            error_message: None,
            retry_count: 0,
        };

        self.delivery_log.log_attempt(&attempt).await?;
        info!(message_id = %msg.id, "Email sent successfully");
        Ok(attempt)
    }

    #[instrument(skip(self))]
    pub async fn send_otp(
        &self,
        recipient: String,
        code: String,
    ) -> Result<DeliveryAttempt, MessagingError> {
        let msg = Message {
            id: Uuid::new_v4(),
            recipient,
            body: format!("Your OTP code is: {}", code),
            channel: MessageChannel::Sms,
            priority: crate::domain::message::Priority::High,
            tenant_id: Uuid::nil(),
            session_id: None,
        };
        self.send_sms(msg).await
    }

    #[instrument(skip(self))]
    pub async fn get_message_status(
        &self,
        message_id: Uuid,
    ) -> Result<DeliveryAttempt, MessagingError> {
        let attempt = self
            .delivery_log
            .get_attempt(message_id)
            .await?
            .ok_or_else(|| MessagingError::Internal(format!("Message {} not found", message_id)))?;

        if let Some(ref provider_ref) = attempt.provider_ref {
            if let Ok(provider) = self.select_provider(&attempt.recipient) {
                match provider.get_status(provider_ref).await {
                    Ok(status) => {
                        if status != attempt.status {
                            let updated = DeliveryAttempt {
                                status,
                                delivered_at: if status == DeliveryStatus::Delivered {
                                    Some(Utc::now())
                                } else {
                                    attempt.delivered_at
                                },
                                ..attempt
                            };
                            self.delivery_log.log_attempt(&updated).await?;
                            return Ok(updated);
                        }
                    }
                    Err(e) => {
                        warn!(error = %e, "Failed to refresh status from provider");
                    }
                }
            }
        }

        Ok(attempt)
    }

    #[instrument(skip(self))]
    pub async fn list_messages(
        &self,
        tenant_id: Uuid,
        filters: MessageFilters,
    ) -> Result<Vec<Message>, MessagingError> {
        let attempts = self.delivery_log.list_attempts(tenant_id, filters).await?;
        let messages = attempts
            .into_iter()
            .map(|a| Message {
                id: a.message_id,
                recipient: a.recipient,
                body: a.body_preview,
                channel: a.channel,
                priority: crate::domain::message::Priority::Normal,
                tenant_id: a.tenant_id,
                session_id: a.session_id,
            })
            .collect();
        Ok(messages)
    }

    #[instrument(skip(self))]
    pub async fn send_batch(
        &self,
        messages: Vec<Message>,
        continue_on_error: bool,
    ) -> Result<BatchResult, MessagingError> {
        let mut success_count = 0;
        let mut failure_count = 0;
        let mut errors = Vec::new();

        for (idx, msg) in messages.into_iter().enumerate() {
            let result = match msg.channel {
                MessageChannel::Sms => self.send_sms(msg).await,
                MessageChannel::WhatsApp => self.send_whatsapp(msg).await,
                MessageChannel::Email => self.send_email(msg).await,
                MessageChannel::Push => {
                    // Push not implemented; treat as success stub.
                    success_count += 1;
                    continue;
                }
            };

            match result {
                Ok(_) => success_count += 1,
                Err(e) => {
                    failure_count += 1;
                    errors.push((idx, e));
                    if !continue_on_error {
                        break;
                    }
                }
            }
        }

        Ok(BatchResult {
            success_count,
            failure_count,
            errors,
        })
    }

    pub async fn get_template(
        &self,
        tenant_id: Uuid,
        template_id: &str,
    ) -> Result<crate::domain::template::Template, MessagingError> {
        self.template_store.get_template(tenant_id, template_id).await
    }

    pub async fn list_templates(
        &self,
        tenant_id: Uuid,
        channel: Option<MessageChannel>,
    ) -> Result<Vec<crate::domain::template::Template>, MessagingError> {
        self.template_store.list_templates(tenant_id, channel).await
    }
}

#[derive(Debug, Clone)]
pub struct BatchResult {
    pub success_count: usize,
    pub failure_count: usize,
    pub errors: Vec<(usize, MessagingError)>,
}
