"""API key authentication adapter."""
import hashlib
import logging
import os
from typing import Optional

import psycopg2
from fastapi import HTTPException, Security
from fastapi.security import APIKeyHeader
from psycopg2.extras import RealDictCursor

from openai_ussd_kernel.api.domain.tenant_context import TenantContext

logger = logging.getLogger(__name__)
api_key_header = APIKeyHeader(name="X-API-Key")

# Fallback for dev / testing when DB is unreachable
_API_KEYS: dict[str, TenantContext] = {
    "test-key-001": TenantContext(
        tenant_id="test-tenant-001",
        api_key="test-key-001",
        rate_limit_tier="standard",
        permissions=["read", "write"],
    ),
}


class PostgresApiKeyRepository:
    """Queries app.api_keys for active, non-expired API keys."""

    def __init__(self, dsn: str = None):
        self.dsn = dsn or os.environ.get("DATABASE_URL", "postgresql://localhost/ussd")

    def validate_key(self, api_key: str) -> Optional[TenantContext]:
        key_hash = hashlib.sha256(api_key.encode()).hexdigest()
        conn = psycopg2.connect(self.dsn)
        try:
            cursor = conn.cursor(cursor_factory=RealDictCursor)
            cursor.execute(
                """
                SELECT application_id, permissions, rate_limit_rpm
                FROM app.api_keys
                WHERE key_hash = %s AND is_active = true AND (expires_at IS NULL OR expires_at > NOW())
                """,
                (key_hash,),
            )
            row = cursor.fetchone()
            if row:
                # Map rate_limit_rpm to tier names heuristically
                rpm = row.get("rate_limit_rpm", 60)
                if rpm >= 1000:
                    tier = "enterprise"
                elif rpm >= 300:
                    tier = "premium"
                else:
                    tier = "standard"
                return TenantContext(
                    tenant_id=str(row["application_id"]),
                    api_key=api_key,
                    rate_limit_tier=tier,
                    permissions=row.get("permissions", ["read"]),
                )
        finally:
            conn.close()
        return None


class ApiKeyAuth:
    """Validates API keys and returns tenant context."""

    def __init__(self) -> None:
        self._repo = PostgresApiKeyRepository()

    async def authenticate(self, api_key: str = Security(api_key_header)) -> TenantContext:
        # Attempt PostgreSQL lookup first
        try:
            ctx = self._repo.validate_key(api_key)
            if ctx:
                return ctx
        except Exception as exc:
            logger.warning("Postgres API key lookup failed: %s", exc)

        # Fallback to hardcoded dev keys
        ctx = _API_KEYS.get(api_key)
        if not ctx:
            logger.warning("Invalid API key attempted")
            raise HTTPException(status_code=401, detail="Invalid API key")
        return ctx
