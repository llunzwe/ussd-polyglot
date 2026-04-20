"""Model domain types."""
from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass(frozen=True)
class ModelVersion:
    model_id: str
    version: str
    language: str
    deployed_at: datetime
    status: str  # active, deprecated, experimental
    metrics: dict[str, float]
