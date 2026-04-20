use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use sqlx::{PgPool, Row};
use tokio::sync::RwLock;
use tracing::{info, warn};
use uuid::Uuid;

use crate::domain::error::MessagingError;
use crate::domain::message::MessageChannel;
use crate::domain::template::Template;
use crate::ports::template_store::TemplateStorePort;

#[derive(Clone)]
pub struct PostgresTemplateStore {
    db: Option<PgPool>,
    fallback: Arc<RwLock<HashMap<String, Template>>>,
}

impl PostgresTemplateStore {
    pub fn new(db: Option<PgPool>) -> Self {
        Self {
            db,
            fallback: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn seed_fallback(&self, templates: Vec<Template>) {
        let mut map = self.fallback.write().await;
        for t in &templates {
            let key = format!("{}:{}", t.tenant_id, t.id);
            map.insert(key, t.clone());
        }
    }

    async fn set_tenant_context(&self, tenant_id: &Uuid) -> Result<(), sqlx::Error> {
        if let Some(ref pool) = self.db {
            sqlx::query("SET LOCAL app.current_tenant_id = $1")
                .bind(tenant_id.to_string())
                .execute(pool)
                .await?;
        }
        Ok(())
    }
}

#[async_trait]
impl TemplateStorePort for PostgresTemplateStore {
    async fn get_template(
        &self,
        tenant_id: Uuid,
        template_id: &str,
    ) -> Result<Template, MessagingError> {
        if let Some(ref pool) = self.db {
            self.set_tenant_context(&tenant_id).await.map_err(|e| {
                warn!("Failed to set tenant context: {}", e);
                MessagingError::Database(e.to_string())
            })?;

            // Try SMS templates first
            let row = sqlx::query::<sqlx::Postgres>(
                r#"
                SELECT template_code, template_name, template_text, is_active, variables
                FROM messaging.sms_templates
                WHERE application_id = $1 AND template_code = $2 AND is_active = true
                "#,
            )
            .bind(tenant_id)
            .bind(template_id)
            .fetch_optional(pool)
            .await
            .map_err(|e: sqlx::Error| {
                warn!("Database query failed: {}", e);
                MessagingError::Database(e.to_string())
            })?;

            if let Some(row) = row {
                let variables_json: Option<serde_json::Value> = row.try_get("variables").ok();
                let variables = parse_variables(variables_json);
                return Ok(Template {
                    id: row.try_get("template_code").unwrap_or_default(),
                    tenant_id,
                    name: row.try_get("template_name").unwrap_or_default(),
                    channel: MessageChannel::Sms,
                    subject: None,
                    body: row.try_get("template_text").unwrap_or_default(),
                    variables,
                    is_active: row.try_get("is_active").unwrap_or(true),
                });
            }

            // Fallback to WhatsApp templates
            let row = sqlx::query::<sqlx::Postgres>(
                r#"
                SELECT template_code, template_name, body_text, is_active, variables
                FROM messaging.whatsapp_templates
                WHERE application_id = $1 AND template_code = $2 AND is_active = true
                "#,
            )
            .bind(tenant_id)
            .bind(template_id)
            .fetch_optional(pool)
            .await
            .map_err(|e: sqlx::Error| {
                warn!("Database query failed: {}", e);
                MessagingError::Database(e.to_string())
            })?;

            if let Some(row) = row {
                let variables_json: Option<serde_json::Value> = row.try_get("variables").ok();
                let variables = parse_variables(variables_json);
                return Ok(Template {
                    id: row.try_get("template_code").unwrap_or_default(),
                    tenant_id,
                    name: row.try_get("template_name").unwrap_or_default(),
                    channel: MessageChannel::WhatsApp,
                    subject: None,
                    body: row.try_get("body_text").unwrap_or_default(),
                    variables,
                    is_active: row.try_get("is_active").unwrap_or(true),
                });
            }
        }

        let key = format!("{}:{}", tenant_id, template_id);
        let map = self.fallback.read().await;
        map.get(&key)
            .cloned()
            .ok_or_else(|| MessagingError::TemplateNotFound(template_id.to_string()))
    }

    async fn list_templates(
        &self,
        tenant_id: Uuid,
        channel: Option<MessageChannel>,
    ) -> Result<Vec<Template>, MessagingError> {
        let mut results: Vec<Template> = Vec::new();

        if let Some(ref pool) = self.db {
            self.set_tenant_context(&tenant_id).await.map_err(|e| {
                warn!("Failed to set tenant context: {}", e);
                MessagingError::Database(e.to_string())
            })?;

            info!("Listing templates from database for tenant {}", tenant_id);

            if channel.is_none() || channel == Some(MessageChannel::Sms) {
                let rows = sqlx::query::<sqlx::Postgres>(
                    r#"
                    SELECT template_code, template_name, template_text, is_active, variables
                    FROM messaging.sms_templates
                    WHERE application_id = $1 AND is_active = true
                    "#,
                )
                .bind(tenant_id)
                .fetch_all(pool)
                .await
                .map_err(|e: sqlx::Error| {
                    warn!("Database query failed: {}", e);
                    MessagingError::Database(e.to_string())
                })?;

                for row in rows {
                    let variables_json: Option<serde_json::Value> = row.try_get("variables").ok();
                    results.push(Template {
                        id: row.try_get("template_code").unwrap_or_default(),
                        tenant_id,
                        name: row.try_get("template_name").unwrap_or_default(),
                        channel: MessageChannel::Sms,
                        subject: None,
                        body: row.try_get("template_text").unwrap_or_default(),
                        variables: parse_variables(variables_json),
                        is_active: row.try_get("is_active").unwrap_or(true),
                    });
                }
            }

            if channel.is_none() || channel == Some(MessageChannel::WhatsApp) {
                let rows = sqlx::query::<sqlx::Postgres>(
                    r#"
                    SELECT template_code, template_name, body_text, is_active, variables
                    FROM messaging.whatsapp_templates
                    WHERE application_id = $1 AND is_active = true
                    "#,
                )
                .bind(tenant_id)
                .fetch_all(pool)
                .await
                .map_err(|e: sqlx::Error| {
                    warn!("Database query failed: {}", e);
                    MessagingError::Database(e.to_string())
                })?;

                for row in rows {
                    let variables_json: Option<serde_json::Value> = row.try_get("variables").ok();
                    results.push(Template {
                        id: row.try_get("template_code").unwrap_or_default(),
                        tenant_id,
                        name: row.try_get("template_name").unwrap_or_default(),
                        channel: MessageChannel::WhatsApp,
                        subject: None,
                        body: row.try_get("body_text").unwrap_or_default(),
                        variables: parse_variables(variables_json),
                        is_active: row.try_get("is_active").unwrap_or(true),
                    });
                }
            }
        }

        if results.is_empty() {
            let map = self.fallback.read().await;
            results = map
                .values()
                .filter(|t| t.tenant_id == tenant_id)
                .cloned()
                .collect();

            if let Some(ch) = channel {
                results.retain(|t| t.channel == ch);
            }
        }

        Ok(results)
    }
}

fn parse_variables(value: Option<serde_json::Value>) -> Vec<String> {
    match value {
        Some(serde_json::Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        _ => Vec::new(),
    }
}
