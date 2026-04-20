"""USSD session domain types."""
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional


class SessionStatus(str, Enum):
    ACTIVE = "active"
    TIMEOUT = "timeout"
    COMPLETED = "completed"
    ERROR = "error"


@dataclass
class UssdSession:
    session_id: str
    phone_number: str
    service_code: str
    network_code: Optional[str] = None
    tenant_id: Optional[str] = None
    status: SessionStatus = SessionStatus.ACTIVE
    state: dict = field(default_factory=dict)
    created_at: datetime = field(default_factory=datetime.utcnow)
    last_activity_at: datetime = field(default_factory=datetime.utcnow)

    def touch(self) -> None:
        self.last_activity_at = datetime.utcnow()

    def is_expired(self, timeout_seconds: float = 180.0) -> bool:
        from datetime import timedelta
        return (datetime.utcnow() - self.last_activity_at).total_seconds() > timeout_seconds
