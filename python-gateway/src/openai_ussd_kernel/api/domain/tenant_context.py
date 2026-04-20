"""Tenant context for API requests."""
from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class TenantContext:
    tenant_id: str
    api_key: str
    rate_limit_tier: str = "standard"  # standard, premium, enterprise
    permissions: list[str] = None
    authenticated_at: datetime = None

    def __post_init__(self):
        object.__setattr__(self, "permissions", self.permissions or ["read"])
        if self.authenticated_at is None:
            object.__setattr__(self, "authenticated_at", datetime.utcnow())

    def can(self, action: str) -> bool:
        return action in self.permissions or "admin" in self.permissions
