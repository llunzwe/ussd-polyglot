use std::time::Duration;

use moka::future::Cache as MokaCache;
use uuid::Uuid;

use crate::domain::session::SessionState;

#[derive(Debug, Clone)]
pub struct CachedSession {
    pub state: SessionState,
    pub event_count: usize,
    pub integrity_hash: String,
    pub last_activity: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone)]
pub struct SessionCache {
    inner: MokaCache<(Uuid, Uuid), CachedSession>,
}

impl SessionCache {
    pub fn new() -> Self {
        let inner = MokaCache::builder()
            .time_to_live(Duration::from_secs(180))
            .build();
        Self { inner }
    }

    pub async fn get(&self, session_id: Uuid, tenant_id: Uuid) -> Option<CachedSession> {
        self.inner.get(&(session_id, tenant_id)).await
    }

    pub async fn insert(&self, session_id: Uuid, tenant_id: Uuid, session: CachedSession) {
        self.inner.insert((session_id, tenant_id), session).await;
    }

    pub async fn invalidate(&self, session_id: Uuid, tenant_id: Uuid) {
        self.inner.invalidate(&(session_id, tenant_id)).await;
    }
}

impl Default for SessionCache {
    fn default() -> Self {
        Self::new()
    }
}
