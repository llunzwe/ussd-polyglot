"""PostgreSQL event consumer for analytics."""
import logging
from datetime import datetime

import psycopg2

logger = logging.getLogger(__name__)


class PostgresEventConsumer:
    """Polling consumer that reads from events.event_store."""

    def __init__(self, dsn: str):
        self.dsn = dsn
        self.last_seen = datetime.utcnow()

    def poll(self, batch_size: int = 100) -> list[dict]:
        conn = psycopg2.connect(self.dsn)
        cursor = conn.cursor()
        cursor.execute(
            """
            SELECT event_type, aggregate_type, aggregate_id, payload, occurred_at, tenant_id
            FROM events.event_store
            WHERE occurred_at > %s
            ORDER BY occurred_at ASC
            LIMIT %s
            """,
            (self.last_seen, batch_size),
        )
        rows = cursor.fetchall()
        conn.close()
        if rows:
            self.last_seen = rows[-1][4]  # occurred_at
        return [
            {
                "event_type": row[0],
                "aggregate_type": row[1],
                "aggregate_id": row[2],
                "payload": row[3],
                "occurred_at": row[4],
                "tenant_id": row[5],
            }
            for row in rows
        ]
