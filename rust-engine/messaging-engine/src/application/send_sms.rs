//! Send SMS use-case.
use crate::domain::delivery::DeliveryAttempt;
use crate::domain::error::MessagingError;
use crate::domain::message::Message;

/// Execute the send-SMS use-case via the unified handler.
pub async fn execute(
    handler: &super::handler::MessagingHandler,
    msg: Message,
) -> Result<DeliveryAttempt, MessagingError> {
    handler.send_sms(msg).await
}
