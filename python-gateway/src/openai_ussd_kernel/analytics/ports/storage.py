"""Analytics storage port interface."""
from typing import Protocol

from openai_ussd_kernel.analytics.domain.metric import Metric
from openai_ussd_kernel.analytics.domain.report import Report


class AnalyticsStoragePort(Protocol):
    """Port for persisting and querying analytics data."""

    def save_metric(self, metric: Metric) -> None:
        ...

    def get_metrics(self, tenant_id: str, metric_type: str, from_date, to_date) -> list[Metric]:
        ...

    def save_report(self, report: Report) -> None:
        ...

    def get_report(self, report_id: str) -> Report:
        ...
