use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde_json::Value;
use uuid::Uuid;

use crate::domain::error::DomainError;

pub type SessionState = HashMap<String, String>;

#[derive(Debug, Clone)]
pub struct EventEnvelope {
    pub event_id: Uuid,
    pub event_type: String,
    pub version: i64,
    pub payload: Value,
    pub occurred_at: DateTime<Utc>,
    pub record_hash: String,
    pub previous_hash: Option<String>,
}

/// Deterministic fold over session events.
pub fn fold_session_state(events: Vec<EventEnvelope>) -> Result<SessionState, DomainError> {
    if events.is_empty() {
        return Err(DomainError::SessionNotFound);
    }

    let mut expected_version = 1i64;
    let mut state = SessionState::new();

    for event in events {
        if event.version != expected_version {
            return Err(DomainError::EventSequenceGap {
                expected: expected_version,
                found: event.version,
            });
        }

        match event.event_type.as_str() {
            "SessionCreated" => {
                state.insert("status".to_string(), "active".to_string());
                if let Some(phone) = event.payload.get("phone_number").and_then(|v| v.as_str()) {
                    state.insert("phone_number".to_string(), phone.to_string());
                }
                if let Some(tenant) = event.payload.get("tenant_id").and_then(|v| v.as_str()) {
                    state.insert("tenant_id".to_string(), tenant.to_string());
                }
            }
            "MenuNavigated" => {
                if let Some(menu) = event.payload.get("menu_id").and_then(|v| v.as_str()) {
                    state.insert("current_menu".to_string(), menu.to_string());
                }
            }
            "InputReceived" => {
                if let Some(input) = event.payload.get("input").and_then(|v| v.as_str()) {
                    state.insert("last_input".to_string(), input.to_string());
                }
            }
            "PaymentInitiated" => {
                state.insert("payment_status".to_string(), "initiated".to_string());
                if let Some(amount) = event.payload.get("amount").and_then(|v| v.as_str()) {
                    state.insert("amount".to_string(), amount.to_string());
                }
                if let Some(currency) = event.payload.get("currency").and_then(|v| v.as_str()) {
                    state.insert("currency".to_string(), currency.to_string());
                }
            }
            "PaymentConfirmed" => {
                state.insert("payment_status".to_string(), "confirmed".to_string());
                if let Some(ref_id) = event.payload.get("reference_id").and_then(|v| v.as_str()) {
                    state.insert("payment_reference".to_string(), ref_id.to_string());
                }
            }
            "SessionEnded" => {
                state.insert("status".to_string(), "ended".to_string());
                if let Some(reason) = event.payload.get("reason").and_then(|v| v.as_str()) {
                    state.insert("end_reason".to_string(), reason.to_string());
                }
            }
            other => return Err(DomainError::InvalidEventType(other.to_string())),
        }

        expected_version += 1;
    }

    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_event(version: i64, event_type: &str, payload: Value) -> EventEnvelope {
        EventEnvelope {
            event_id: Uuid::new_v4(),
            event_type: event_type.to_string(),
            version,
            payload,
            occurred_at: Utc::now(),
            record_hash: format!("hash-{version}"),
            previous_hash: if version == 1 { None } else { Some(format!("hash-{}", version - 1)) },
        }
    }

    #[test]
    fn empty_events_returns_not_found() {
        let res = fold_session_state(vec![]);
        assert!(matches!(res, Err(DomainError::SessionNotFound)));
    }

    #[test]
    fn session_created_sets_active() {
        let events = vec![make_event(
            1,
            "SessionCreated",
            serde_json::json!({"phone_number": "+123"}),
        )];
        let state = fold_session_state(events).unwrap();
        assert_eq!(state.get("status"), Some(&"active".to_string()));
        assert_eq!(state.get("phone_number"), Some(&"+123".to_string()));
    }

    #[test]
    fn menu_navigated_sets_current_menu() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(2, "MenuNavigated", serde_json::json!({"menu_id": "main"})),
        ];
        let state = fold_session_state(events).unwrap();
        assert_eq!(state.get("current_menu"), Some(&"main".to_string()));
    }

    #[test]
    fn input_received_sets_last_input() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(2, "InputReceived", serde_json::json!({"input": "1234"})),
        ];
        let state = fold_session_state(events).unwrap();
        assert_eq!(state.get("last_input"), Some(&"1234".to_string()));
    }

    #[test]
    fn payment_flow() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(
                2,
                "PaymentInitiated",
                serde_json::json!({"amount": "100", "currency": "USD"}),
            ),
            make_event(
                3,
                "PaymentConfirmed",
                serde_json::json!({"reference_id": "ref-42"}),
            ),
        ];
        let state = fold_session_state(events).unwrap();
        assert_eq!(state.get("payment_status"), Some(&"confirmed".to_string()));
        assert_eq!(state.get("amount"), Some(&"100".to_string()));
        assert_eq!(state.get("currency"), Some(&"USD".to_string()));
        assert_eq!(state.get("payment_reference"), Some(&"ref-42".to_string()));
    }

    #[test]
    fn session_ended_sets_status() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(2, "SessionEnded", serde_json::json!({"reason": "timeout"})),
        ];
        let state = fold_session_state(events).unwrap();
        assert_eq!(state.get("status"), Some(&"ended".to_string()));
        assert_eq!(state.get("end_reason"), Some(&"timeout".to_string()));
    }

    #[test]
    fn event_sequence_gap_detected() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(3, "MenuNavigated", serde_json::json!({"menu_id": "main"})),
        ];
        let res = fold_session_state(events);
        assert!(
            matches!(res, Err(DomainError::EventSequenceGap { expected: 2, found: 3 }))
        );
    }

    #[test]
    fn invalid_event_type_returns_error() {
        let events = vec![
            make_event(1, "SessionCreated", serde_json::json!({})),
            make_event(2, "UnknownEvent", serde_json::json!({})),
        ];
        let res = fold_session_state(events);
        assert!(
            matches!(res, Err(DomainError::InvalidEventType(t)) if t == "UnknownEvent")
        );
    }
}
