# Ledger Query Service Implementation Guide

## Overview

The Ledger Query Service (LQS) is a Rust CQRS read-side service providing tenant applications with analytical queries over the kernel's immutable ledger. It does **NOT** write to the ledger — all writes go through the Go Orchestrator (`AppendEvent`).

## CQRS Read Model Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL 16 + TimescaleDB                                 │
│  ├─ core.transaction_log (WORM, hash-chained)               │
│  ├─ core.account_registry                                   │
│  ├─ core.settlement_instructions                            │
│  ├─ core.suspense_items                                     │
│  ├─ analytics.daily_aggregates (continuous aggregate)       │
│  └─ analytics.monthly_aggregates (continuous aggregate)     │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ AccountQuery │ │ Transaction  │ │ Settlement   │
│ Service      │ │ Query Service│ │ Query Service│
│ (6 methods)  │ │ (12 methods) │ │ (4 methods)  │
└──────────────┘ └──────────────┘ └──────────────┘
```

## Query Services

The LQS exposes 6 gRPC services with 35 total methods:

| Service | Methods | Data Source |
|---------|---------|-------------|
| `AccountQuery` | 6 | `core.account_registry`, `core.account_balances` |
| `TransactionQuery` | 12 | `core.transaction_log`, `analytics.*` |
| `SettlementQuery` | 4 | `core.settlement_instructions` |
| `SuspenseQuery` | 4 | `core.suspense_items` |
| `ReconciliationQuery` | 5 | `reconciliation.reports`, `reconciliation.mismatches` |
| `AnalyticsQuery` | 4 | `analytics.*` continuous aggregates |

## TimescaleDB Continuous Aggregates

### Daily Aggregates

```sql
CREATE MATERIALIZED VIEW analytics.daily_aggregates
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 day', committed_at) AS bucket,
  application_id,
  transaction_type,
  COUNT(*) AS txn_count,
  SUM(amount_cents) AS total_amount_cents
FROM core.transaction_log
GROUP BY bucket, application_id, transaction_type;
```

### Refresh Policy

```sql
SELECT add_continuous_aggregate_policy('analytics.daily_aggregates',
  start_offset => INTERVAL '1 month',
  end_offset => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');
```

## Materialized View Refresh Strategy

| View | Refresh Strategy | Latency |
|------|-----------------|---------|
| `analytics.daily_aggregates` | Continuous (TimescaleDB) | Real-time |
| `analytics.monthly_aggregates` | Daily at 02:00 UTC | ~24h |
| `analytics.provider_summary` | On-demand (API trigger) | < 5s |

## Query Patterns

### Account Balance

```rust
// GET /v1/accounts/{account_id}/balance
let balance = sqlx::query_as::<_, AccountBalance>(
    "SELECT account_id, available_balance_cents, held_balance_cents, currency_code
     FROM core.account_balances
     WHERE account_id = $1 AND tenant_id = $2"
)
.bind(account_id)
.bind(tenant_id)
.fetch_one(&self.pool)
.await?;
```

### Transaction History

```rust
// GET /v1/transactions?account_id=...&start=...&end=...
let txns = sqlx::query_as::<_, Transaction>(
    "SELECT transaction_uuid, transaction_type, amount_cents, currency_code, committed_at
     FROM core.transaction_log
     WHERE account_id = $1 AND tenant_id = $2 AND committed_at BETWEEN $3 AND $4
     ORDER BY committed_at DESC
     LIMIT $5 OFFSET $6"
)
// ... bindings
.fetch_all(&self.pool)
.await?;
```

### Settlement Status

```rust
// GET /v1/settlements/{settlement_id}/status
let settlement = sqlx::query_as::<_, Settlement>(
    "SELECT settlement_id, status, total_amount_cents, settled_at
     FROM core.settlement_instructions
     WHERE settlement_id = $1 AND tenant_id = $2"
)
.fetch_one(&self.pool)
.await?;
```

## RLS & Tenant Isolation

Every query method **must** set the tenant context before execution:

```rust
async fn set_tenant_context(&self, tenant_id: &Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("SET LOCAL app.current_tenant_id = $1")
        .bind(tenant_id.to_string())
        .execute(&self.pool)
        .await?;
    Ok(())
}
```

Failure to set this context will result in empty result sets due to RLS policies on `core.transaction_log`.

## Performance Optimization

1. **Connection pooling**: PgBouncer with `transaction` pool mode
2. **Read replicas**: LQS connects to read replicas for analytical queries
3. **Query caching**: Redis for hot account balances (TTL 30s)
4. **Cursor pagination**: `LIMIT`/`OFFSET` for large transaction lists
5. **Index hints**: TimescaleDB auto-indexes on `committed_at`

## Security

- Read-only database user (`ledger_query_reader`)
- RLS enforced at database level
- No direct access to `events.event_store` (Go-only)
- gRPC mTLS between LQS and API Gateway

## Monitoring

- `lqs_query_duration_seconds` — Histogram by query type
- `lqs_query_errors_total` — Counter by error type
- `lqs_cache_hit_ratio` — Gauge
- `lqs_active_connections` — Gauge
