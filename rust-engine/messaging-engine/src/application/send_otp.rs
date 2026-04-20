//! Send OTP use-case.
use crate::domain::delivery::DeliveryAttempt;
use crate::domain::error::MessagingError;

/// Execute the send-OTP use-case via the unified handler.
pub async fn execute(
    handler: &super::handler::MessagingHandler,
    recipient: String,
    code: String,
) -> Result<DeliveryAttempt, MessagingError> {
    handler.send_otp(recipient, code).await
}
