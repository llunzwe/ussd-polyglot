# Operations Runbook

**Version**: 1.0.0  
**Status**: Draft  
**Last Updated**: 2026-04-13  
**Owner**: Site Reliability Engineering  

---

## 1. Incident Response

### 1.1 Severity Levels

| Level | Description | Examples | Response Time | Team |
|-------|-------------|----------|---------------|------|
| **P1 - Critical** | Complete service outage | Database down, all USSD failing | 15 minutes | On-call + Management |
| **P2 - High** | Major functionality impaired | Payment processing down | 30 minutes | On-call |
| **P3 - Medium** | Minor functionality impaired | AI translation slow | 2 hours | Engineering |
| **P4 - Low** | Cosmetic issues, feature requests | Documentation typo | 1 day | Backlog |

### 1.2 Incident Command Structure

```
Incident Commander (IC)
├── Technical Lead (TL)
│   ├── Database Specialist
│   ├── Application Engineer
│   └── Network Engineer
├── Communications Lead (CL)
│   ├── Internal Updates
│   └── External Updates
└── Scribe
    └── Timeline Documentation
```

### 1.3 Runbook: Database Connection Pool Exhaustion

**Symptoms**:
- Error: "FATAL: sorry, too many clients already"
- High latency on all requests
- Connection timeouts

**Diagnosis**:
```bash
# Check active connections
psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Check connection pool usage
psql -U postgres -c "
SELECT 
    pool_mode,
    cl_active,
    cl_waiting,
    sv_active,
    sv_idle
FROM pgbouncer.stats;
"

# Identify long-running queries
psql -U postgres -c "
SELECT 
    pid,
    now() - query_start as duration,
    state,
    left(query, 100) as query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC
LIMIT 10;
"
```

**Resolution**:
```bash
# 1. Kill idle connections (if safe)
psql -U postgres -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
AND state_change < NOW() - INTERVAL '1 hour';
"

# 2. Restart pgBouncer (if needed)
kubectl rollout restart deployment/pgbouncer

# 3. Scale up database connections
kubectl patch configmap pgbouncer-config --patch '{"data":{"default_pool_size": "50"}}'

# 4. Identify and fix connection leak in application
# Review application logs for unclosed connections
```

**Post-Incident**:
- [ ] Document root cause
- [ ] Update connection pool configuration
- [ ] Add monitoring alert for connection usage > 80%
- [ ] Review application connection handling

---

### 1.4 Runbook: Hash Chain Break Detected

**Symptoms**:
- Alert: "Hash chain verification failed"
- `integrity.consistency_checks` shows failed status

**Diagnosis**:
```sql
-- Find broken record
SELECT 
    transaction_id,
    record_hash,
    previous_hash,
    core.generate_row_hash(
        'core.transaction_log',
        transaction_uuid,
        jsonb_build_object(
            'transaction_type_id', transaction_type_id,
            'initiator_account_id', initiator_account_id,
            'amount', amount,
            'status', status
        ),
        committed_at,
        previous_hash
    ) as computed_hash
FROM core.transaction_log
WHERE chain_sequence > (
    SELECT MIN(chain_sequence) 
    FROM integrity.consistency_checks 
    WHERE status = 'failed'
)
ORDER BY chain_sequence
LIMIT 10;
```

**Severity Assessment**:
- **Single record tampered**: P1 - Potential security breach
- **Multiple records**: P0 - Active attack or catastrophic failure

**Immediate Actions**:
```bash
# 1. Stop all writes to preserve evidence
kubectl scale deployment go-orchestrator --replicas=0

# 2. Preserve database state
pg_dump -U postgres ussd_kernel > /forensics/backup-$(date +%s).sql

# 3. Notify security team
slack-alert "#security" "Hash chain break detected. All writes suspended."

# 4. Enable enhanced logging
kubectl set env deployment/go-orchestrator LOG_LEVEL=debug
```

**Investigation**:
```sql
-- Check audit log for suspicious activity
SELECT 
    changed_at,
    changed_by,
    operation,
    table_name,
    record_id
FROM audit.change_log
WHERE table_name = 'core.transaction_log'
AND changed_at > NOW() - INTERVAL '24 hours'
ORDER BY changed_at DESC;

-- Check session activity
SELECT 
    session_id,
    user_id,
    total_queries,
    total_transactions,
    client_ip
FROM audit.session_log
WHERE suspicious_activity_detected = true
AND session_started_at > NOW() - INTERVAL '24 hours';
```

**Recovery** (if confirmed as data corruption, not attack):
```bash
# Restore from verified backup
psql -U postgres -c "DROP DATABASE ussd_kernel;"
psql -U postgres -c "CREATE DATABASE ussd_kernel;"
pg_restore -U postgres -d ussd_kernel /backups/verified/ussd_kernel.dump

# Rebuild hash chain
cargo run --bin hash-chain-rebuild

# Verify integrity
psql -U postgres -c "SELECT integrity.compute_batch_hash(CURRENT_DATE);"
```

---

### 1.5 Runbook: Mobile Money Provider Adapter Down

**Symptoms**:
- Payment failures with "Provider timeout"
- Callbacks not received

**Diagnosis**:
```bash
# Check provider health
curl -H "X-API-Key: $ECOCASH_API_KEY" \
  https://api.ecocash.co.zw/v1/health

# Check kernel adapter connectivity
kubectl exec -it deployment/rust-payment-engine -- \
  curl -I https://api.ecocash.co.zw/v1/health

# Check recent payment attempts
psql -U postgres -c "
SELECT 
    mobile_money_provider,
    status,
    COUNT(*)
FROM core.transaction_log
WHERE is_mobile_money = true
AND committed_at > NOW() - INTERVAL '1 hour'
GROUP BY 1, 2;
"
```

**Resolution**:
```bash
# 1. Enable circuit breaker (if not automatic)
kubectl set env deployment/rust-payment-engine \
  ECOCASH_CIRCUIT_BREAKER=OPEN

# 2. Switch to backup provider (if available)
kubectl set env deployment/rust-payment-engine \
  DEFAULT_PROVIDER=onemoney

# 3. Queue failed payments for retry
redis-cli LPUSH payment_retry_queue '{"payment_id": "..."}'

# 4. Notify tenant applications of temporary provider issue
# (Through tenant applications)
```

**Recovery**:
```bash
# 1. Verify provider is back
curl -H "X-API-Key: $ECOCASH_API_KEY" \
  https://api.ecocash.co.zw/v1/health

# 2. Close circuit breaker
kubectl set env deployment/rust-payment-engine \
  ECOCASH_CIRCUIT_BREAKER=CLOSED

# 3. Process queued payments
cargo run --bin process-payment-retry-queue

# 4. Reconcile with provider
psql -U postgres -f reconcile_payments.sql
```

---

## 2. Daily Operations

### 2.1 Morning Checks

```bash
#!/bin/bash
# morning-checks.sh

echo "=== USSD Kernel Morning Checks ==="
echo "Date: $(date)"

# 1. Service Health
echo -e "\n[1/10] Service Health"
kubectl get pods -n ussd-kernel | grep -v Running && echo "⚠️  Non-running pods detected"
curl -s http://go-orchestrator:8080/health | grep -q "SERVING" && echo "✓ Orchestrator healthy" || echo "✗ Orchestrator unhealthy"
curl -s http://rust-payment:9092/health | grep -q "SERVING" && echo "✓ Payment engine healthy" || echo "✗ Payment engine unhealthy"

# 2. Database
echo -e "\n[2/10] Database Health"
psql -U postgres -c "SELECT 1;" > /dev/null 2>&1 && echo "✓ PostgreSQL responding" || echo "✗ PostgreSQL down"
redis-cli ping | grep -q "PONG" && echo "✓ Redis responding" || echo "✗ Redis down"

# 3. Hash Chain
echo -e "\n[3/10] Hash Chain Verification"
LATEST_BATCH=$(psql -U postgres -t -c "SELECT batch_hash FROM integrity.batch_hashes ORDER BY batch_date DESC LIMIT 1;")
[ ! -z "$LATEST_BATCH" ] && echo "✓ Latest batch hash: ${LATEST_BATCH:0:16}..." || echo "✗ No batch hash found"

# 4. Transaction Volume
echo -e "\n[4/10] Transaction Volume (24h)"
psql -U postgres -c "
SELECT 
    COUNT(*) as tx_count,
    COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed,
    ROUND(100.0 * COUNT(CASE WHEN status = 'failed' THEN 1 END) / COUNT(*), 2) as failure_rate
FROM core.transaction_log
WHERE committed_at > NOW() - INTERVAL '24 hours';
"

# 5. Session Stats
echo -e "\n[5/10] Session Statistics"
psql -U postgres -c "
SELECT 
    COUNT(*) FILTER (WHERE status = 'ACTIVE') as active_sessions,
    COUNT(*) FILTER (WHERE status = 'TIMEOUT') as timeouts_24h
FROM ussd.ussd_sessions
WHERE created_at > NOW() - INTERVAL '24 hours';
"

# 6. Payment Stats
echo -e "\n[6/10] Payment Statistics"
psql -U postgres -c "
SELECT 
    mobile_money_provider,
    COUNT(*) as count,
    COUNT(CASE WHEN status = 'completed' THEN 1 END) as successful
FROM core.transaction_log
WHERE is_mobile_money = true
AND committed_at > NOW() - INTERVAL '24 hours'
GROUP BY 1;
"

# 7. Disk Usage
echo -e "\n[7/10] Disk Usage"
df -h /var/lib/postgresql | tail -1 | awk '{print "PostgreSQL data: " $5 " used"}'
df -h /backups | tail -1 | awk '{print "Backups: " $5 " used"}'

# 8. Memory Usage
echo -e "\n[8/10] Memory Usage"
kubectl top pods -n ussd-kernel | head -5

# 9. Error Rate
echo -e "\n[9/10] Error Rate (last hour)"
ERROR_RATE=$(kubectl logs -n ussd-kernel deployment/go-orchestrator --since=1h | grep -c ERROR || echo "0")
TOTAL_LOGS=$(kubectl logs -n ussd-kernel deployment/go-orchestrator --since=1h | wc -l)
if [ $TOTAL_LOGS -gt 0 ]; then
    RATE=$(echo "scale=2; $ERROR_RATE * 100 / $TOTAL_LOGS" | bc)
    echo "Error rate: ${RATE}% (${ERROR_RATE} errors)"
else
    echo "No logs found"
fi

# 10. SSL Certificate Expiry
echo -e "\n[10/10] SSL Certificates"
EXPIRY=$(echo | openssl s_client -servername api.ussd-kernel.org -connect api.ussd-kernel.org:443 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
NOW_EPOCH=$(date +%s)
DAYS_UNTIL_EXPIRY=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
if [ $DAYS_UNTIL_EXPIRY -lt 30 ]; then
    echo "⚠️  SSL expires in ${DAYS_UNTIL_EXPIRY} days!"
else
    echo "✓ SSL valid for ${DAYS_UNTIL_EXPIRY} days"
fi

echo -e "\n=== Checks Complete ==="
```

---

## 3. Maintenance Procedures

### 3.1 Database Maintenance Window

**Pre-Maintenance**:
```bash
# 1. Notify stakeholders
slack-alert "#ops" "Database maintenance starting in 30 minutes"

# 2. Enable maintenance mode
kubectl set env deployment/python-gateway MAINTENANCE_MODE=true

# 3. Drain connections
psql -U postgres -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename NOT IN ('postgres', 'replicator')
AND pid <> pg_backend_pid();
"
```

**During Maintenance**:
```bash
# 1. Analyze tables
psql -U postgres -c "ANALYZE core.transaction_log;"
psql -U postgres -c "ANALYZE events.event_store;"

# 2. Reindex (if needed)
psql -U postgres -c "REINDEX INDEX CONCURRENTLY idx_transaction_log_uuid;"

# 3. Update statistics
psql -U postgres -c "VACUUM ANALYZE;"
```

**Post-Maintenance**:
```bash
# 1. Disable maintenance mode
kubectl set env deployment/python-gateway MAINTENANCE_MODE=false

# 2. Verify services
./morning-checks.sh

# 3. Notify completion
slack-alert "#ops" "Database maintenance complete. All systems operational."
```

### 3.2 Certificate Renewal

```bash
#!/bin/bash
# renew-certificate.sh

DOMAIN="api.ussd-kernel.org"
CERT_NAME="ussd-kernel-tls"

# 1. Request new certificate
certbot certonly --dns-route53 -d $DOMAIN

# 2. Update Kubernetes secret
kubectl create secret tls $CERT_NAME \
    --cert=/etc/letsencrypt/live/$DOMAIN/fullchain.pem \
    --key=/etc/letsencrypt/live/$DOMAIN/privkey.pem \
    --dry-run=client -o yaml | kubectl apply -f -

# 3. Rolling restart to pick up new cert
kubectl rollout restart deployment/go-orchestrator
kubectl rollout restart deployment/python-gateway
kubectl rollout restart deployment/rust-payment-engine

# 4. Verify
openssl s_client -connect $DOMAIN:443 -servername $DOMAIN < /dev/null 2>/dev/null | openssl x509 -noout -text | grep "Not After"
```

---

## 4. Capacity Planning

### 4.1 Growth Projections

| Metric | Current | 6 Months | 12 Months |
|--------|---------|----------|-----------|
| Tenant Daily Transactions | 10,000 | 50,000 | 200,000 |
| Active Sessions | 1,000 | 5,000 | 20,000 |
| Storage (monthly) | 100 GB | 500 GB | 2 TB |
| API Requests/sec | 100 | 500 | 2,000 |

### 4.2 Scaling Triggers

| Resource | Warning | Critical | Action |
|----------|---------|----------|--------|
| Database CPU | > 70% | > 85% | Scale up / Read replicas |
| Database Storage | > 75% | > 90% | Archive old data |
| Memory Usage | > 80% | > 95% | Scale pods / Add nodes |
| Connection Pool | > 80% | > 95% | Increase pool size |
| Response Time | > 100ms | > 500ms | Optimize queries |

---

## 5. Disaster Recovery

### 5.1 RTO/RPO

| Scenario | RTO | RPO |
|----------|-----|-----|
| Single pod failure | 1 min | 0 |
| Node failure | 5 min | 0 |
| AZ failure | 15 min | 0 |
| Database corruption | 30 min | 15 min |
| Complete region loss | 4 hours | 1 hour |

### 5.2 Failover Procedures

**Database Failover**:
```bash
# 1. Promote replica
repmgr standby promote --force

# 2. Update application connection strings
kubectl set env deployment/go-orchestrator \
    DB_HOST=new-primary.postgres.local

# 3. Restart applications
kubectl rollout restart deployment/go-orchestrator

# 4. Verify
psql -h new-primary.postgres.local -U postgres -c "SELECT pg_is_in_recovery();"
```

---

## 6. Security Procedures

### 6.1 Access Revocation

```bash
# 1. Revoke database access
psql -U postgres -c "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA core FROM old_user;"

# 2. Rotate API keys
kubectl create secret generic api-keys-new --from-literal=ecocash=newkey
kubectl rollout restart deployment/rust-payment-engine
kubectl delete secret api-keys-old

# 3. Invalidate sessions in Redis
redis-cli KEYS "session:*" | xargs redis-cli DEL

# 4. Audit trail
psql -U postgres -c "
INSERT INTO audit.security_events 
(event_type, user_id, action, timestamp)
VALUES ('ACCESS_REVOKED', 'old_user', 'Complete access revocation', NOW());
"
```

### 6.2 Security Incident Response

```bash
# 1. Isolate affected systems
kubectl taint nodes affected-node security=incident:NoSchedule
kubectl drain affected-node --ignore-daemonsets

# 2. Preserve evidence
kubectl logs affected-pod --all-containers > /incidents/logs-$(date +%s).txt
docker save affected-image > /incidents/image-$(date +%s).tar

# 3. Contact security team
page-oncall-security "Security incident detected on $(hostname)"

# 4. Begin forensic analysis
# (Follow security team procedures)
```

---

**Next Review Date**: 2026-05-13  
**Owner**: SRE Team  
**Escalation Path**: SRE Lead → Engineering Manager → CTO
