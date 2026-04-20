"""Redis client wrapper for gateway state management."""

import logging
from typing import Any

import redis

from openai_ussd_kernel.gateway.config import settings

logger = logging.getLogger("python-gateway")


class RedisClient:
    """Singleton Redis client for rate limiting and session tracking."""

    _instance: "RedisClient | None" = None

    def __new__(cls) -> "RedisClient":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self) -> None:
        if self._initialized:
            return
        try:
            self._client = redis.from_url(settings.redis_url, decode_responses=True)
            self._client.ping()
            self._available = True
            logger.info("Redis connection established")
        except redis.RedisError as exc:
            self._client = None
            self._available = False
            logger.warning("Redis unavailable, falling back to in-memory: %s", exc)
        self._initialized = True

    @property
    def available(self) -> bool:
        return self._available and self._client is not None

    @property
    def client(self) -> redis.Redis:
        if self._client is None:
            raise RuntimeError("Redis client not available")
        return self._client

    def close(self) -> None:
        if self._client:
            self._client.close()


def get_redis() -> RedisClient:
    return RedisClient()
