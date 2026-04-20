use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Message {
    pub id: Uuid,
    pub recipient: String,
    pub body: String,
    pub channel: MessageChannel,
    pub priority: Priority,
    pub tenant_id: Uuid,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageChannel {
    Sms,
    WhatsApp,
    Email,
    Push,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Priority {
    Low,
    Normal,
    High,
    Critical,
}

/// Pure domain logic: route by Zimbabwe phone prefix.
/// - 26377 / 26378 -> EcoCash
/// - 26371 / 26372 -> OneMoney
/// - 26373 / 26374 -> TeleCash
pub fn route_provider(recipient: &str) -> Option<super::provider::Provider> {
    let normalized = recipient.trim_start_matches('+');
    if normalized.starts_with("26377") || normalized.starts_with("26378") {
        Some(super::provider::Provider::EcoCash)
    } else if normalized.starts_with("26371") || normalized.starts_with("26372") {
        Some(super::provider::Provider::OneMoney)
    } else if normalized.starts_with("26373") || normalized.starts_with("26374") {
        Some(super::provider::Provider::TeleCash)
    } else {
        None
    }
}
