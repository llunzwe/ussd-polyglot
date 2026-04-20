"""Rate limiting dependency for FastAPI."""
import logging
import time
from functools import wraps

from fastapi import HTTPException, Request

from openai_ussd_kernel.infrastructure.redis_client import get_redis

logger = logging.getLogger(__name__)


class RateLimitMiddleware:
    """FastAPI dependency for per-tenant rate limiting."""

    def __init__(self, requests_per_minute: int = 60):
        self.requests_per_minute = requests_per_minute
        self._redis = get_redis()

    async def __call__(self, request: Request):
        tenant_id = request.path_params.get("tenant_id", "unknown")
        key = f"api_rate_limit:{tenant_id}"

        if self._redis.available:
            now = time.time()
            pipe = self._redis.client.pipeline()
            pipe.zremrangebyscore(key, 0, now - 60)
            pipe.zcard(key)
            pipe.zadd(key, {str(now): now})
            pipe.expire(key, 61)
            results = pipe.execute()
            count = results[1]
            if count >= self.requests_per_minute:
                raise HTTPException(status_code=429, detail="Rate limit exceeded")
        return None
