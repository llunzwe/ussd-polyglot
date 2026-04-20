use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;
use tracing::{info, warn};

#[derive(Clone)]
pub struct RedisRateLimiter {
    redis: Option<redis::aio::MultiplexedConnection>,
    fallback: Arc<Mutex<HashMap<String, u32>>>,
}

impl RedisRateLimiter {
    pub async fn new(redis_url: Option<String>) -> Self {
        let redis = if let Some(url) = redis_url {
            match redis::Client::open(url) {
                Ok(client) => match client.get_multiplexed_tokio_connection().await {
                    Ok(conn) => Some(conn),
                    Err(e) => {
                        warn!("Failed to connect to Redis: {}", e);
                        None
                    }
                },
                Err(e) => {
                    warn!("Invalid Redis URL: {}", e);
                    None
                }
            }
        } else {
            None
        };

        Self {
            redis,
            fallback: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn check_and_increment(&self, tenant_id: &str, limit: u32) -> bool {
        if let Some(ref mut conn) = self.redis.clone() {
            let key = format!("rate_limit:{}", tenant_id);
            match redis::cmd("INCR")
                .arg(&key)
                .query_async::<_, u32>(conn)
                .await
            {
                Ok(c) => {
                    if c == 1 {
                        let _ = redis::cmd("EXPIRE")
                            .arg(&key)
                            .arg(60)
                            .query_async::<_, ()>(conn)
                            .await;
                    }
                    c <= limit
                }
                Err(e) => {
                    warn!("Redis rate limit error: {}", e);
                    self.fallback_check(tenant_id, limit).await
                }
            }
        } else {
            self.fallback_check(tenant_id, limit).await
        }
    }

    async fn fallback_check(&self, tenant_id: &str, limit: u32) -> bool {
        let mut map = self.fallback.lock().await;
        let count = map.entry(tenant_id.to_string()).or_insert(0);
        *count += 1;
        info!(
            "Rate limit fallback for tenant {}: {}/{}",
            tenant_id, *count, limit
        );
        *count <= limit
    }
}
