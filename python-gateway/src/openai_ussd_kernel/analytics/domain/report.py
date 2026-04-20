"""Analytics report domain types."""
from dataclasses import dataclass
from datetime import datetime
from enum import Enum


class ReportFormat(str, Enum):
    JSON = "json"
    CSV = "csv"
    PDF = "pdf"


@dataclass(frozen=True)
class Report:
    report_id: str
    tenant_id: str
    report_type: str
    format: ReportFormat
    generated_at: datetime
    download_url: str
    expires_at: datetime
