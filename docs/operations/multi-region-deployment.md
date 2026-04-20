# Multi-Region Deployment Guide

## Overview

The Open AI-USSD Kernel Engine is designed for multi-region deployment across Southern Africa, with primary operations in Zimbabwe and DR capabilities in South Africa or Zambia.

## Deployment Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Global Load Balancer                            │
│                     (Cloudflare / AWS Global Accelerator)                │
└─────────────────────┬─────────────────────────────┬─────────────────────┘
                      │ Geo-routing by MSISDN prefix │
        ┌─────────────┴─────────────┐   ┌───────────┴─────────────┐
        ▼                           ▼   ▼                         ▼
┌───────────────┐           ┌───────────────┐           ┌───────────────┐
│  Harare (ZA)  │◄─────────►│  Bulawayo     │◄─────────►│  Cape Town    │
│  Primary      │  Sync     │  Secondary    │  Async    │  DR           │
│  Region       │  Repl     │  Region       │  Repl     │  Region       │
└───────┬───────┘           └───────┬───────┘           └───────┬───────┘
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐           ┌───────────────┐           ┌───────────────┐
│  K8s Cluster  │           │  K8s Cluster  │           │  K8s Cluster  │
│  - Go Orch    │           │  - Go Orch    │           │  - Go Orch    │
│  - Rust PE    │           │  - Rust PE    │           │  - Rust PE    │
│  - Python GW  │           │  - Python GW  │           │  - Python GW  │
│  - Postgres   │◄─────────►│  - Postgres   │◄─────────►│  - Postgres   │
│    (Primary)  │           │    (Replica)  │           │    (Standby)  │
└───────────────┘           └───────────────┘           └───────────────┘
```

## Kubernetes Deployment

### Namespace Structure

```yaml
# Per-region namespaces
apiVersion: v1
kind: Namespace
metadata:
  name: ussd-production
  labels:
    region: harare-1
    tier: production
```

### Pod Affinity / Anti-Affinity

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: go-orchestrator
        topologyKey: topology.kubernetes.io/zone
```

### Resource Quotas

| Service | Requests | Limits | Replicas per Region |
|---------|----------|--------|---------------------|
| Go Orchestrator | 2 CPU, 4Gi | 4 CPU, 8Gi | 3 |
| Rust Payment Engine | 2 CPU, 4Gi | 4 CPU, 8Gi | 3 |
| Rust Messaging Engine | 1 CPU, 2Gi | 2 CPU, 4Gi | 2 |
| Python Gateway | 1 CPU, 2Gi | 2 CPU, 4Gi | 3 |
| Ledger Query Service | 1 CPU, 2Gi | 2 CPU, 4Gi | 2 |

## Data Replication Strategy

### Synchronous Replication (Primary ↔ Secondary)

For `core.transaction_log` and `events.event_store` within the primary region:

```sql
-- On primary (Harare)
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (bulawayo_replica)';
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
SELECT pg_reload_conf();
```

Latency target: < 10ms (same metropolitan area)

### Asynchronous Replication (Secondary → DR)

For cross-region DR (Bulawayo → Cape Town):

```sql
-- On Bulawayo
ALTER SYSTEM SET synchronous_standby_names = '';
ALTER SYSTEM SET synchronous_commit = 'local';
```

Latency target: < 200ms (acceptable for DR)

### Logical Replication (Analytics)

For read-heavy analytics workloads:

```sql
-- Publish only aggregate data
CREATE PUBLICATION region_analytics FOR TABLE analytics.daily_aggregates;
```

## Latency Optimization

### 1. Regional Caching

Redis Cluster per region with cross-region invalidation:

```
Harare Redis    ←── async replication ──►    Bulawayo Redis
    │                                              │
    └─── session data, hot balances                └─── read-only cache
```

### 2. Connection Pooling

PgBouncer per region:

```ini
[databases]
ussd = host=postgres-primary.internal port=5432 dbname=ussd

[pgbouncer]
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 25
reserve_pool_size = 5
```

### 3. gRPC Load Balancing

Use Kubernetes headless services for gRPC client-side load balancing:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-orchestrator-grpc
spec:
  clusterIP: None  # Headless
  selector:
    app: go-orchestrator
  ports:
    - port: 50051
      name: grpc
```

## Failover Procedures

### Regional Failover (Harare → Bulawayo)

1. **Promote Bulawayo PostgreSQL**:
   ```bash
   pg_ctl promote
   ```
2. **Update Kubernetes endpoints**:
   ```bash
   kubectl patch configmap ussd-config \
     --patch '{"data":{"DB_PRIMARY":"bulawayo-postgres.internal"}}'
   ```
3. **Restart services** with new primary:
   ```bash
   kubectl rollout restart deployment/go-orchestrator
   ```
4. **Update DNS** to point to Bulawayo ingress

### Service-Level Failover

Use Kubernetes native mechanisms:

```yaml
livenessProbe:
  grpc:
    port: 50051
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 3

readinessProbe:
  exec:
    command:
      - /bin/grpc_health_probe
      - -addr=:50051
  periodSeconds: 5
```

## Network Topology

### Inter-Region Connectivity

- **Primary ↔ Secondary**: Dedicated 10Gbps fiber (same country)
- **Secondary → DR**: VPN over public internet with WireGuard
- **Management plane**: Out-of-band network

### Security Groups / Firewall Rules

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Any | Python Gateway | 443 | HTTPS | USSD webhooks |
| Internal | Go Orchestrator | 50051 | gRPC | Internal services |
| Internal | PostgreSQL | 5432 | PostgreSQL | Database access |
| Internal | Redis | 6379 | Redis | Caching |
| PgBouncer | PostgreSQL | 5432 | PostgreSQL | Connection pooling |

## Monitoring per Region

### Prometheus Federation

```yaml
# global Prometheus scrapes regional instances
scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{job=~"ussd_.*"}'
    static_configs:
      - targets:
        - 'prometheus.harare.internal:9090'
        - 'prometheus.bulawayo.internal:9090'
        - 'prometheus.capetown.internal:9090'
```

### Cross-Region Latency Alerts

```yaml
- alert: HighCrossRegionReplicationLag
  expr: pg_stat_replication_pg_wal_lsn_diff / 1024 / 1024 > 100
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Cross-region replication lag > 100MB"
```

## Deployment Checklist

- [ ] PostgreSQL streaming replication configured
- [ ] PgBouncer deployed on all nodes
- [ ] Redis Cluster with persistence
- [ ] Vault CSI for secrets
- [ ] mTLS certificates rotated
- [ ] Prometheus federation configured
- [ ] Alertmanager routing per region
- [ ] Backup verification completed
- [ ] DR drill executed
- [ ] RBZ/POTRAZ notified of topology
