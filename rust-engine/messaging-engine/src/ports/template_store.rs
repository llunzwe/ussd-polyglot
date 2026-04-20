use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{error::MessagingError, message::MessageChannel, template::Template};

#[async_trait]
pub trait TemplateStorePort: Send + Sync {
    async fn get_template(
        &self,
        tenant_id: Uuid,
        template_id: &str,
    ) -> Result<Template, MessagingError>;
    async fn list_templates(
        &self,
        tenant_id: Uuid,
        channel: Option<MessageChannel>,
    ) -> Result<Vec<Template>, MessagingError>;
}
