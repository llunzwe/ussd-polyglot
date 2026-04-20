//! Broadcast use-case (batch messaging).
use crate::domain::error::MessagingError;
use crate::domain::message::Message;

/// Execute a broadcast via the unified handler.
pub async fn execute(
    handler: &super::handler::MessagingHandler,
    messages: Vec<Message>,
    continue_on_error: bool,
) -> Result<super::handler::BatchResult, MessagingError> {
    handler.send_batch(messages, continue_on_error).await
}
