use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::domain::error::DomainError;
use crate::domain::session::{fold_session_state, EventEnvelope, SessionState};
use crate::infrastructure::cache::{CachedSession, SessionCache};
use crate::infrastructure::postgres::PgEventStore;

pub struct ReconstructSessionResult {
    pub session_id: Uuid,
    pub state: SessionState,
    pub event_count: usize,
    pub integrity_hash: String,
    pub last_activity: Option<DateTime<Utc>>,
    pub current_version: i64,
}

pub struct IntegrityResult {
    pub is_valid: bool,
    pub computed_hash: String,
    pub event_count: i64,
    pub broken_at_version: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct ReconstructSessionHandler {
    pub store: PgEventStore,
    pub cache: SessionCache,
}

impl ReconstructSessionHandler {
    pub fn new(store: PgEventStore, cache: SessionCache) -> Self {
        Self { store, cache }
    }

    pub async fn reconstruct_session(
        &self,
        session_id: Uuid,
        tenant_id: Uuid,
        max_events: i32,
    ) -> Result<ReconstructSessionResult, DomainError> {
        if let Some(cached) = self.cache.get(session_id, tenant_id).await {
            return Ok(ReconstructSessionResult {
                session_id,
                state: cached.state,
                event_count: cached.event_count,
                integrity_hash: cached.integrity_hash,
                last_activity: cached.last_activity,
                current_version: cached.event_count as i64,
            });
        }

        let db_events = self
            .store
            .fetch_events(session_id, tenant_id, max_events)
            .await
            .map_err(|e| DomainError::Internal(e.to_string()))?;

        if db_events.is_empty() {
            return Err(DomainError::SessionNotFound);
        }

        let envelopes: Vec<EventEnvelope> = db_events
            .iter()
            .map(|e| EventEnvelope {
                event_id: e.event_id,
                event_type: e.event_type.clone(),
                version: e.version,
                payload: e.payload.clone(),
                occurred_at: e.occurred_at,
                record_hash: e.record_hash.clone(),
                previous_hash: e.previous_hash.clone(),
            })
            .collect();

        let last_activity = envelopes.last().map(|e| e.occurred_at);
        let current_version = envelopes.last().map(|e| e.version).unwrap_or(0);
        let integrity_hash = envelopes
            .last()
            .map(|e| e.record_hash.clone())
            .unwrap_or_default();

        let state = fold_session_state(envelopes)?;
        let event_count = db_events.len();

        let cached = CachedSession {
            state: state.clone(),
            event_count,
            integrity_hash: integrity_hash.clone(),
            last_activity,
        };
        self.cache.insert(session_id, tenant_id, cached).await;

        Ok(ReconstructSessionResult {
            session_id,
            state,
            event_count,
            integrity_hash,
            last_activity,
            current_version,
        })
    }

    pub async fn verify_integrity(
        &self,
        session_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<IntegrityResult, DomainError> {
        let db_events = self
            .store
            .fetch_events(session_id, tenant_id, i32::MAX)
            .await
            .map_err(|e| DomainError::Internal(e.to_string()))?;

        if db_events.is_empty() {
            return Err(DomainError::SessionNotFound);
        }

        let mut expected_version = 1i64;
        let mut last_computed_hash = String::new();

        for event in &db_events {
            if event.version != expected_version {
                return Err(DomainError::EventSequenceGap {
                    expected: expected_version,
                    found: event.version,
                });
            }

            let prev = event
                .previous_hash
                .as_ref()
                .map(|s| s.as_str())
                .unwrap_or("")
                .to_string();

            // For the first event, if previous_hash is None, use empty string.
            // Otherwise, the previous_hash must match the last computed hash (chain continuity).
            if expected_version > 1 && prev != last_computed_hash {
                return Err(DomainError::HashMismatch {
                    version: event.version,
                });
            }

            let previous_hash = if expected_version == 1 {
                prev
            } else {
                last_computed_hash.clone()
            };

            let computed = compute_event_hash(
                &previous_hash,
                &event.event_type,
                &event.payload,
                &event.occurred_at,
            );

            if computed != event.record_hash {
                return Ok(IntegrityResult {
                    is_valid: false,
                    computed_hash: computed,
                    event_count: db_events.len() as i64,
                    broken_at_version: Some(event.version),
                });
            }

            last_computed_hash = computed;
            expected_version += 1;
        }

        Ok(IntegrityResult {
            is_valid: true,
            computed_hash: last_computed_hash,
            event_count: db_events.len() as i64,
            broken_at_version: None,
        })
    }

    pub async fn fetch_event_hashes(
        &self,
        session_id: Uuid,
        tenant_id: Uuid,
    ) -> Result<Vec<String>, DomainError> {
        let db_events = self
            .store
            .fetch_events(session_id, tenant_id, i32::MAX)
            .await
            .map_err(|e| DomainError::Internal(e.to_string()))?;

        if db_events.is_empty() {
            return Err(DomainError::SessionNotFound);
        }

        Ok(db_events.into_iter().map(|e| e.record_hash).collect())
    }
}

fn compute_event_hash(
    previous_hash: &str,
    event_type: &str,
    payload: &serde_json::Value,
    occurred_at: &DateTime<Utc>,
) -> String {
    let payload_str = serde_json::to_string(payload).unwrap_or_default();
    let input = format!(
        "{}{}{}{}",
        previous_hash,
        event_type,
        payload_str,
        occurred_at.to_rfc3339()
    );
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn compute_merkle_proof(hashes: &[String], target_index: usize) -> (String, Vec<String>) {
    if hashes.is_empty() {
        return (String::new(), vec![]);
    }
    let mut current: Vec<Vec<u8>> = hashes
        .iter()
        .map(|h| hex::decode(h).unwrap_or_default())
        .collect();
    let mut siblings = vec![];
    let mut idx = target_index;

    while current.len() > 1 {
        if current.len() % 2 == 1 {
            current.push(current.last().unwrap().clone());
        }
        let sibling_idx = if idx % 2 == 0 { idx + 1 } else { idx - 1 };
        siblings.push(hex::encode(&current[sibling_idx]));
        let mut next = Vec::with_capacity(current.len() / 2);
        for i in (0..current.len()).step_by(2) {
            let mut hasher = Sha256::new();
            hasher.update(&current[i]);
            hasher.update(&current[i + 1]);
            next.push(hasher.finalize().to_vec());
        }
        current = next;
        idx /= 2;
    }

    (hex::encode(&current[0]), siblings)
}
