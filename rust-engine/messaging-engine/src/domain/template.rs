use uuid::Uuid;

use super::message::MessageChannel;

#[derive(Debug, Clone)]
pub struct Template {
    pub id: String,
    pub tenant_id: Uuid,
    pub name: String,
    pub channel: MessageChannel,
    pub subject: Option<String>,
    pub body: String,
    pub variables: Vec<String>,
    pub is_active: bool,
}

/// Pure function for variable substitution using {{key}} syntax.
pub fn render_template(
    template: &Template,
    vars: &std::collections::HashMap<String, String>,
) -> String {
    let mut result = template.body.clone();
    for (key, value) in vars {
        let placeholder = format!("{{{{{}}}}}" , key);
        result = result.replace(&placeholder, value);
    }
    result
}
