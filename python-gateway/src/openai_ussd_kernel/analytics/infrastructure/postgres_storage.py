"""PostgreSQL analytics storage adapter."""
import json
import logging
import os
from datetime import datetime, timedelta

import psycopg2

from openai_ussd_kernel.analytics.domain.metric import Metric
from openai_ussd_kernel.analytics.domain.report import Report

logger = logging.getLogger(__name__)


class PostgresAnalyticsStorage:
    """PostgreSQL storage for analytics metrics and reports."""

    def __init__(self, connection_string: str = ""):
        self._connection_string = connection_string or os.environ.get("DATABASE_URL", "")

    def _conn(self):
        return psycopg2.connect(self._connection_string)

    def save_metric(self, metric: Metric) -> None:
        if not self._connection_string:
            logger.warning("No DATABASE_URL configured; metric not persisted")
            return
        try:
            conn = self._conn()
            cursor = conn.cursor()
            cursor.execute(
                """
                INSERT INTO observability.metrics
                (tenant_id, metric_type, value, labels, recorded_at)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (
                    metric.tenant_id,
                    metric.metric_type.value if hasattr(metric.metric_type, "value") else str(metric.metric_type),
                    metric.value,
                    json.dumps(metric.labels) if hasattr(metric, "labels") else "{}",
                    metric.timestamp,
                ),
            )
            conn.commit()
            conn.close()
            logger.debug("Saved metric %s for tenant %s", metric.metric_type, metric.tenant_id)
        except Exception as exc:
            logger.warning("Failed to save metric: %s", exc)

    def get_metrics(self, tenant_id: str, metric_type: str, from_date, to_date) -> list[Metric]:
        if not self._connection_string:
            return []
        try:
            conn = self._conn()
            cursor = conn.cursor()
            cursor.execute(
                """
                SELECT tenant_id, metric_type, value, labels, recorded_at
                FROM observability.metrics
                WHERE tenant_id = %s AND metric_type = %s AND recorded_at BETWEEN %s AND %s
                ORDER BY recorded_at DESC
                """,
                (tenant_id, metric_type, from_date, to_date),
            )
            rows = cursor.fetchall()
            conn.close()
            return [
                Metric(
                    tenant_id=row[0],
                    metric_type=row[1],
                    value=row[2],
                    labels=json.loads(row[3]) if row[3] else {},
                    timestamp=row[4],
                )
                for row in rows
            ]
        except Exception as exc:
            logger.warning("Failed to get metrics: %s", exc)
            return []

    def save_report(self, report: Report) -> None:
        if not self._connection_string:
            logger.warning("No DATABASE_URL configured; report not persisted")
            return
        try:
            conn = self._conn()
            cursor = conn.cursor()
            cursor.execute(
                """
                INSERT INTO observability.reports
                (report_id, tenant_id, report_type, data, generated_at)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (report_id) DO UPDATE SET
                    data = EXCLUDED.data,
                    generated_at = EXCLUDED.generated_at
                """,
                (
                    report.report_id,
                    report.tenant_id,
                    report.report_type.value if hasattr(report.report_type, "value") else str(report.report_type),
                    json.dumps(report.data) if hasattr(report, "data") else "{}",
                    report.generated_at,
                ),
            )
            conn.commit()
            conn.close()
            logger.info("Saved report %s", report.report_id)
        except Exception as exc:
            logger.warning("Failed to save report: %s", exc)

    def get_report(self, report_id: str) -> Report | None:
        if not self._connection_string:
            return None
        try:
            conn = self._conn()
            cursor = conn.cursor()
            cursor.execute(
                "SELECT report_id, tenant_id, report_type, data, generated_at FROM observability.reports WHERE report_id = %s",
                (report_id,),
            )
            row = cursor.fetchone()
            conn.close()
            if row:
                return Report(
                    report_id=row[0],
                    tenant_id=row[1],
                    report_type=row[2],
                    data=json.loads(row[3]) if row[3] else {},
                    generated_at=row[4],
                )
            return None
        except Exception as exc:
            logger.warning("Failed to get report: %s", exc)
            return None
