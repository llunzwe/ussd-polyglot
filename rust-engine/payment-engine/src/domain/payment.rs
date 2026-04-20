use regex::Regex;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use uuid::Uuid;

use crate::domain::error::DomainError;
use crate::domain::provider::{MobileMoneyProvider, ProviderStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PaymentStatus {
    Pending,
    Processing,
    Completed,
    Failed,
    Cancelled,
    Refunded,
}

impl PaymentStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            PaymentStatus::Pending => "pending",
            PaymentStatus::Processing => "processing",
            PaymentStatus::Completed => "completed",
            PaymentStatus::Failed => "failed",
            PaymentStatus::Cancelled => "cancelled",
            PaymentStatus::Refunded => "refunded",
        }
    }
}

impl std::fmt::Display for PaymentStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Payment {
    pub payment_id: Uuid,
    pub tenant_id: Uuid,
    pub idempotency_key: String,
    pub provider: MobileMoneyProvider,
    pub phone_number: String,
    pub amount: Decimal,
    pub currency: String,
    pub reference: String,
    pub description: String,
    pub status: PaymentStatus,
    pub provider_reference: Option<String>,
    pub failure_reason: Option<String>,
    pub initiated_at: chrono::DateTime<chrono::Utc>,
    pub completed_at: Option<chrono::DateTime<chrono::Utc>>,
}

static PHONE_RE: OnceLock<Regex> = OnceLock::new();

impl Payment {
    pub fn new(
        payment_id: Uuid,
        tenant_id: Uuid,
        idempotency_key: impl Into<String>,
        provider: MobileMoneyProvider,
        phone_number: impl Into<String>,
        amount: Decimal,
        currency: impl Into<String>,
        reference: impl Into<String>,
        description: impl Into<String>,
    ) -> Result<Self, DomainError> {
        let phone_number = phone_number.into();
        let reference = reference.into();
        let currency = currency.into();

        if amount <= Decimal::ZERO {
            return Err(DomainError::InvalidAmount(
                "Amount must be greater than zero".to_string(),
            ));
        }
        if reference.trim().is_empty() {
            return Err(DomainError::InvalidReference(
                "Reference must not be empty".to_string(),
            ));
        }

        let re = PHONE_RE.get_or_init(|| Regex::new(r"^2637[1378]\d{8}$").unwrap());
        if !re.is_match(&phone_number) {
            return Err(DomainError::InvalidPhoneNumber(phone_number));
        }

        Ok(Self {
            payment_id,
            tenant_id,
            idempotency_key: idempotency_key.into(),
            provider,
            phone_number,
            amount,
            currency,
            reference,
            description: description.into(),
            status: PaymentStatus::Pending,
            provider_reference: None,
            failure_reason: None,
            initiated_at: chrono::Utc::now(),
            completed_at: None,
        })
    }

    pub fn validate(&self) -> Result<(), DomainError> {
        if self.amount <= Decimal::ZERO {
            return Err(DomainError::InvalidAmount(
                "Amount must be greater than zero".to_string(),
            ));
        }
        if self.reference.trim().is_empty() {
            return Err(DomainError::InvalidReference(
                "Reference must not be empty".to_string(),
            ));
        }
        let re = PHONE_RE.get_or_init(|| Regex::new(r"^2637[1378]\d{8}$").unwrap());
        if !re.is_match(&self.phone_number) {
            return Err(DomainError::InvalidPhoneNumber(self.phone_number.clone()));
        }
        Ok(())
    }

    pub fn mark_processing(&mut self) -> Result<(), DomainError> {
        match self.status {
            PaymentStatus::Pending | PaymentStatus::Processing => {
                self.status = PaymentStatus::Processing;
                Ok(())
            }
            _ => Err(DomainError::InvalidStatusTransition {
                from: self.status.to_string(),
                to: PaymentStatus::Processing.to_string(),
            }),
        }
    }

    pub fn mark_completed(&mut self, provider_ref: impl Into<String>) -> Result<(), DomainError> {
        match self.status {
            PaymentStatus::Pending | PaymentStatus::Processing => {
                self.status = PaymentStatus::Completed;
                self.provider_reference = Some(provider_ref.into());
                self.completed_at = Some(chrono::Utc::now());
                Ok(())
            }
            _ => Err(DomainError::InvalidStatusTransition {
                from: self.status.to_string(),
                to: PaymentStatus::Completed.to_string(),
            }),
        }
    }

    pub fn mark_failed(&mut self, reason: impl Into<String>) -> Result<(), DomainError> {
        match self.status {
            PaymentStatus::Pending | PaymentStatus::Processing => {
                self.status = PaymentStatus::Failed;
                self.failure_reason = Some(reason.into());
                self.completed_at = Some(chrono::Utc::now());
                Ok(())
            }
            _ => Err(DomainError::InvalidStatusTransition {
                from: self.status.to_string(),
                to: PaymentStatus::Failed.to_string(),
            }),
        }
    }

    pub fn mark_refunded(&mut self) -> Result<(), DomainError> {
        match self.status {
            PaymentStatus::Completed => {
                self.status = PaymentStatus::Refunded;
                self.completed_at = Some(chrono::Utc::now());
                Ok(())
            }
            _ => Err(DomainError::InvalidStatusTransition {
                from: self.status.to_string(),
                to: PaymentStatus::Refunded.to_string(),
            }),
        }
    }

    pub fn apply_provider_status(&mut self, status: ProviderStatus, provider_ref: Option<String>) {
        match status {
            ProviderStatus::Completed => {
                let _ = self.mark_completed(provider_ref.unwrap_or_default());
            }
            ProviderStatus::Failed => {
                let _ = self.mark_failed("Provider reported failure");
            }
            ProviderStatus::Cancelled => {
                if self.status == PaymentStatus::Pending || self.status == PaymentStatus::Processing
                {
                    self.status = PaymentStatus::Cancelled;
                    self.completed_at = Some(chrono::Utc::now());
                }
            }
            ProviderStatus::Refunded => {
                let _ = self.mark_refunded();
            }
            ProviderStatus::Processing => {
                let _ = self.mark_processing();
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_payment() -> Payment {
        Payment::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "idem-123",
            MobileMoneyProvider::EcoCash,
            "2637123456789",
            Decimal::new(100, 0),
            "USD",
            "REF-001",
            "Test payment",
        )
        .unwrap()
    }

    #[test]
    fn test_new_valid_payment() {
        let p = valid_payment();
        assert_eq!(p.status, PaymentStatus::Pending);
        assert!(p.provider_reference.is_none());
    }

    #[test]
    fn test_invalid_phone_number() {
        let result = Payment::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "idem",
            MobileMoneyProvider::EcoCash,
            "2639123456789", // invalid prefix
            Decimal::new(100, 0),
            "USD",
            "REF",
            "desc",
        );
        assert!(matches!(result, Err(DomainError::InvalidPhoneNumber(_))));
    }

    #[test]
    fn test_invalid_amount() {
        let result = Payment::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "idem",
            MobileMoneyProvider::EcoCash,
            "2637123456789",
            Decimal::ZERO,
            "USD",
            "REF",
            "desc",
        );
        assert!(matches!(result, Err(DomainError::InvalidAmount(_))));
    }

    #[test]
    fn test_empty_reference() {
        let result = Payment::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            "idem",
            MobileMoneyProvider::EcoCash,
            "2637123456789",
            Decimal::new(10, 0),
            "USD",
            "  ",
            "desc",
        );
        assert!(matches!(result, Err(DomainError::InvalidReference(_))));
    }

    #[test]
    fn test_mark_processing() {
        let mut p = valid_payment();
        assert!(p.mark_processing().is_ok());
        assert_eq!(p.status, PaymentStatus::Processing);
    }

    #[test]
    fn test_mark_completed() {
        let mut p = valid_payment();
        p.mark_processing().unwrap();
        assert!(p.mark_completed("PROV-REF-001").is_ok());
        assert_eq!(p.status, PaymentStatus::Completed);
        assert_eq!(p.provider_reference, Some("PROV-REF-001".to_string()));
    }

    #[test]
    fn test_mark_failed() {
        let mut p = valid_payment();
        assert!(p.mark_failed("Insufficient balance").is_ok());
        assert_eq!(p.status, PaymentStatus::Failed);
        assert_eq!(p.failure_reason, Some("Insufficient balance".to_string()));
    }

    #[test]
    fn test_invalid_status_transition_completed_to_processing() {
        let mut p = valid_payment();
        p.mark_processing().unwrap();
        p.mark_completed("REF").unwrap();
        assert!(p.mark_processing().is_err());
    }

    #[test]
    fn test_refund_from_completed() {
        let mut p = valid_payment();
        p.mark_processing().unwrap();
        p.mark_completed("REF").unwrap();
        assert!(p.mark_refunded().is_ok());
        assert_eq!(p.status, PaymentStatus::Refunded);
    }

    #[test]
    fn test_refund_from_pending_fails() {
        let mut p = valid_payment();
        assert!(p.mark_refunded().is_err());
    }
}
