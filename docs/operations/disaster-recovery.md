# Disaster Recovery Procedures

## Overview

This document defines disaster recovery (DR) procedures for the Open AI-USSD Kernel Engine, a polyglot USSD kernel that provides SDK and API endpoints for tenant applications integrating with mobile money systems in Zimbabwe.

## RTO / RPO Targets

| Tier | Service | RTO | RPO | Recovery Method |
|------|---------|-----|-----|-----------------|
| T0 | core.transaction_log | 15 min | 0 (sync) | Cross-region streaming replication |
| T1 | events.event_store | 15 min | 0 (sync) | Cross-region streaming replication |
| T2 | Go Orchestrator | 30 min | 0 | Active-passive failover |
| T3 | Rust Payment Engine | 30 min | < 5 min | Outbox replay from secondary |
| T4 | Python Gateway | 60 min | < 30 min | Blue-green deployment |
| T5 | Analytics / LQS | 4 hours | < 1 hour | Read replica promotion |

## PostgreSQL Point-in-Time Recovery (PITR)

### Continuous Archiving

WAL archiving is configured with `archive_mode = on`:

```ini
# postgresql.conf
archive_mode = on
archive_command = 'cp %p /wal_archive/%f'
archive_timeout = 60
wal_level = replica
max_wal_senders = 10
```

WAL files are archived to S3-compatible object storage every 60 seconds.

### Base Backup Schedule

```bash
# Daily base backup at 02:00 UTC
pg_basebackup -D /backups/$(date +%Y%m%d) -Fp -Xs -P -v

# Upload to S3
aws s3 sync /backups/$(date +%Y%m%d) s3://ussd-dr-backups/postgres/$(date +%Y%m%d)/
```

### Recovery Procedure

1. **Provision standby instance** in DR region
2. **Restore base backup**:
   ```bash
   pg_basebackup -D /var/lib/postgresql/data -X stream -P -v -h primary.ussd.internal
   ```
3. **Configure recovery**:
   ```ini
   # postgresql.auto.conf
   restore_command = 'aws s3 cp s3://ussd-dr-backups/wal/%f %p || exit 0'
   recovery_target_time = '2026-04-17T10:00:00Z'
   recovery_target_action = 'promote'
   ```
4. **Start PostgreSQL** and monitor `pg_stat_wal_receiver`
5. **Verify hash chain integrity** (see below)
6. **Update DNS / service discovery** to point to promoted standby

## Cross-Region Replication Setup

### Streaming Replication

```ini
# primary postgresql.conf
synchronous_standby_names = 'FIRST 1 (dr_region_1, dr_region_2)'
synchronous_commit = remote_apply
```

### Logical Replication (selective tables)

For analytics read replicas:

```sql
-- On primary
CREATE PUBLICATION analytics_pub FOR TABLE analytics.daily_aggregates, analytics.monthly_aggregates;

-- On subscriber
CREATE SUBSCRIPTION analytics_sub 
    CONNECTION 'host=primary.ussd.internal dbname=ussd user=replicator' 
    PUBLICATION analytics_pub;
```

## Ledger Integrity Verification After Failover

After any failover, verify the hash chain before accepting new transactions:

```bash
# Run from Rust audit service
cargo run --bin audit -- verify-hash-chain \
  --from-time "2026-04-17T00:00:00Z" \
  --to-time "2026-04-17T12:00:00Z" \
  --tenant-id "*"
```

### Manual Verification SQL

```sql
-- Check for hash chain breaks
SELECT 
    transaction_id,
    record_hash,
    previous_hash,
    LAG(record_hash) OVER (ORDER BY committed_at, transaction_id) AS expected_previous_hash
FROM core.transaction_log
WHERE committed_at >= '2026-04-17T00:00:00Z'
ORDER BY committed_at
LIMIT 1000;
```

Any `previous_hash != LAG(record_hash)` indicates a chain break — **DO NOT PROCESS NEW TRANSACTIONS** until resolved.

## Service Recovery Procedures

### Go Orchestrator (Active-Passive)

1. **Detect failure** via health check (`/health` returns non-200 for 30s)
2. **Promote passive instance**:
   ```bash
   kubectl patch deployment go-orchestrator-dr \
     -p '{"spec":{"replicas":1}}'
   ```
3. **Verify outbox poller** is running and catching up
4. **Update load balancer** target group

### Rust Payment Engine

1. **Verify outbox queue depth**:
   ```sql
   SELECT COUNT(*) FROM events.cdc_outbox WHERE processed_at IS NULL;
   ```
2. **If > 1000 unprocessed**, scale up poller instances temporarily
3. **Replay from secondary** if primary data is corrupt:
   ```bash
   cargo run --bin payment-engine -- replay-outbox --from-id <last_known_good>
   ```

### Python Gateway

1. **Blue-green deployment**:
   ```bash
   kubectl apply -f deployments/edge/python-gateway-green.yml
   kubectl patch service python-gateway -p '{"spec":{"selector":{"version":"green"}}}'
   ```
2. **Verify AT webhook endpoints** are responding
3. **Check Redis session cache** is warm

## Failure Scenarios

### Scenario 1: Primary Database Complete Loss

| Step | Action | Owner | Time |
|------|--------|-------|------|
| 1 | Alert on-call engineer | PagerDuty | 0 min |
| 2 | Promote DR PostgreSQL | SRE | 5 min |
| 3 | Verify hash chain | Audit Service | 10 min |
| 4 | Update connection strings | SRE | 12 min |
| 5 | Restart Go Orchestrator | SRE | 15 min |
| 6 | Verify end-to-end transaction | QA | 20 min |

### Scenario 2: Region-Wide Outage

| Step | Action | Owner | Time |
|------|--------|-------|------|
| 1 | Failover DNS to DR region | SRE | 5 min |
| 2 | Activate DR Kubernetes cluster | SRE | 10 min |
| 3 | Promote DR PostgreSQL | SRE | 15 min |
| 4 | Verify all services healthy | SRE | 25 min |
| 5 | Notify RBZ/POTRAZ compliance | Compliance | 30 min |

### Scenario 3: Ledger Corruption Detection

1. **Immediate**: Stop all transaction processing
2. **Assess**: Run `integrity.compute_batch_hash()` for last 24h
3. **Isolate**: Determine corruption scope (tenant, time range)
4. **Recover**: Restore from PITR to last known good state
5. **Verify**: Full hash chain verification
6. **Resume**: Process with RBZ approval

## Contact List

| Role | Contact | Escalation |
|------|---------|-----------|
| On-call SRE | PagerDuty rotation | +15 min → Engineering Manager |
| Database Admin | PagerDuty rotation | +15 min → CTO |
| Compliance Officer | compliance@ussd.kernel | +30 min → RBZ |
| RBZ Emergency | +263-xxx-xxxx | N/A |

## Testing Schedule

| Test Type | Frequency | Last Run | Next Run |
|-----------|-----------|----------|----------|
| DR Failover Drill | Quarterly | — | TBD |
| PITR Restore Test | Monthly | — | TBD |
| Hash Chain Verify | Weekly | — | TBD |
| Cross-region Latency | Continuous | — | — |
