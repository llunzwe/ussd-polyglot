use chrono::{DateTime, Utc};
use sqlx::{Pool, Postgres};
use uuid::Uuid;

use crate::domain::error::DomainError;
use crate::domain::payment::{Payment, PaymentStatus};
use crate::domain::provider::MobileMoneyProvider;

#[derive(Debug, Clone)]
pub struct PgPaymentRepository {
    pool: Pool<Postgres>,
}

impl PgPaymentRepository {
    pub fn new(pool: Pool<Postgres>) -> Self {
        Self { pool }
    }

    async fn set_tenant(&self, tenant_id: Uuid) -> Result<(), DomainError> {
        sqlx::query("SET LOCAL app.current_tenant_id = $1")
            .bind(tenant_id.to_string())
            .execute(&self.pool)
            .await
            .map_err(|e| DomainError::DatabaseError(e.to_string()))?;
        Ok(())
    }

    pub async fn find_by_idempotency_key(
        &self,
        tenant_id: Uuid,
        key: &str,
    ) -> Result<Option<Payment>, DomainError> {
        self.set_tenant(tenant_id).await?;

        let row: Option<PaymentRow> = sqlx::query_as(
            r#"
            SELECT
                payment_id, tenant_id, idempotency_key, provider,
                phone_number, amount, currency, reference, description,
                status, provider_reference, failure_reason,
                initiated_at, completed_at
            FROM payment_engine.payments
            WHERE idempotency_key = $1
            "#,
        )
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        row.map(TryInto::try_into).transpose()
    }

    pub async fn save_payment(&self, payment: &Payment) -> Result<(), DomainError> {
        self.set_tenant(payment.tenant_id).await?;

        sqlx::query(
            r#"
            INSERT INTO payment_engine.payments (
                payment_id, tenant_id, idempotency_key, provider,
                phone_number, amount, currency, reference, description,
                status, provider_reference, failure_reason,
                initiated_at, completed_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
            ON CONFLICT (payment_id) DO UPDATE SET
                status = EXCLUDED.status,
                provider_reference = EXCLUDED.provider_reference,
                failure_reason = EXCLUDED.failure_reason,
                completed_at = EXCLUDED.completed_at
            "#,
        )
        .bind(payment.payment_id)
        .bind(payment.tenant_id)
        .bind(&payment.idempotency_key)
        .bind(payment.provider.as_str())
        .bind(&payment.phone_number)
        .bind(payment.amount.to_string())
        .bind(&payment.currency)
        .bind(&payment.reference)
        .bind(&payment.description)
        .bind(payment.status.as_str())
        .bind(&payment.provider_reference)
        .bind(&payment.failure_reason)
        .bind(payment.initiated_at)
        .bind(payment.completed_at)
        .execute(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        Ok(())
    }

    pub async fn get_payment_by_provider_ref(
        &self,
        tenant_id: Option<Uuid>,
        provider_ref: &str,
    ) -> Result<Option<Payment>, DomainError> {
        if let Some(tid) = tenant_id {
            self.set_tenant(tid).await?;
        }

        let row: Option<PaymentRow> = sqlx::query_as(
            r#"
            SELECT
                payment_id, tenant_id, idempotency_key, provider,
                phone_number, amount, currency, reference, description,
                status, provider_reference, failure_reason,
                initiated_at, completed_at
            FROM payment_engine.payments
            WHERE provider_reference = $1
            "#,
        )
        .bind(provider_ref)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        row.map(TryInto::try_into).transpose()
    }

    pub async fn get_payment_by_id(
        &self,
        tenant_id: Uuid,
        payment_id: Uuid,
    ) -> Result<Option<Payment>, DomainError> {
        self.set_tenant(tenant_id).await?;

        let row: Option<PaymentRow> = sqlx::query_as(
            r#"
            SELECT
                payment_id, tenant_id, idempotency_key, provider,
                phone_number, amount, currency, reference, description,
                status, provider_reference, failure_reason,
                initiated_at, completed_at
            FROM payment_engine.payments
            WHERE payment_id = $1
            "#,
        )
        .bind(payment_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        row.map(TryInto::try_into).transpose()
    }

    pub async fn get_payment_by_id_untenantized(
        &self,
        payment_id: Uuid,
    ) -> Result<Option<Payment>, DomainError> {
        let row: Option<PaymentRow> = sqlx::query_as(
            r#"
            SELECT
                payment_id, tenant_id, idempotency_key, provider,
                phone_number, amount, currency, reference, description,
                status, provider_reference, failure_reason,
                initiated_at, completed_at
            FROM payment_engine.payments
            WHERE payment_id = $1
            "#,
        )
        .bind(payment_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| DomainError::DatabaseError(e.to_string()))?;

        row.map(TryInto::try_into).transpose()
    }
}

#[derive(sqlx::FromRow)]
struct PaymentRow {
    payment_id: Uuid,
    tenant_id: Uuid,
    idempotency_key: String,
    provider: String,
    phone_number: String,
    amount: String,
    currency: String,
    reference: String,
    description: String,
    status: String,
    provider_reference: Option<String>,
    failure_reason: Option<String>,
    initiated_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
}

impl TryFrom<PaymentRow> for Payment {
    type Error = DomainError;

    fn try_from(row: PaymentRow) -> Result<Self, Self::Error> {
        let provider = match row.provider.as_str() {
            "ecocash" => MobileMoneyProvider::EcoCash,
            "onemoney" => MobileMoneyProvider::OneMoney,
            "telecash" => MobileMoneyProvider::Telecash,
            other => {
                return Err(DomainError::DatabaseError(format!(
                    "Unknown provider: {}",
                    other
                )))
            }
        };

        let status = match row.status.as_str() {
            "pending" => PaymentStatus::Pending,
            "processing" => PaymentStatus::Processing,
            "completed" => PaymentStatus::Completed,
            "failed" => PaymentStatus::Failed,
            "cancelled" => PaymentStatus::Cancelled,
            "refunded" => PaymentStatus::Refunded,
            other => {
                return Err(DomainError::DatabaseError(format!(
                    "Unknown status: {}",
                    other
                )))
            }
        };

        Ok(Payment {
            payment_id: row.payment_id,
            tenant_id: row.tenant_id,
            idempotency_key: row.idempotency_key,
            provider,
            phone_number: row.phone_number,
            amount: row.amount.parse().map_err(|e| DomainError::DatabaseError(format!("Invalid amount in DB: {}", e)))?,
            currency: row.currency,
            reference: row.reference,
            description: row.description,
            status,
            provider_reference: row.provider_reference,
            failure_reason: row.failure_reason,
            initiated_at: row.initiated_at,
            completed_at: row.completed_at,
        })
    }
}
