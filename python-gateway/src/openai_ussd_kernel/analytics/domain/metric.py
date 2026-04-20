"""Analytics metric domain types."""
from dataclasses import dataclass
from datetime import datetime
from enum import Enum


class MetricType(str, Enum):
    SESSION_COUNT = "session_count"
    PAYMENT_VOLUME = "payment_volume"
    PAYMENT_COUNT = "payment_count"
    ACTIVE_USERS = "active_users"
    CONVERSION_RATE = "conversion_rate"
    AVG_SESSION_DURATION = "avg_session_duration"
    ERROR_RATE = "error_rate"


@dataclass(frozen=True)
class Metric:
    metric_type: MetricType
    tenant_id: str
    value: float
    currency: str = ""
    timestamp: datetime = None
    dimensions: dict = None

    def __post_init__(self):
        object.__setattr__(self, "dimensions", self.dimensions or {})
        if self.timestamp is None:
            object.__setattr__(self, "timestamp", datetime.utcnow())
