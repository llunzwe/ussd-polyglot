# Security Guardrails (GL-SEC-xxx)

**Version**: 1.0.0  
**Status**: Approved for Enterprise Implementation  
**Classification**: CONFIDENTIAL  
**Last Updated**: 2026-04-13  
**Owner**: Security & Compliance Team  

---

## 1. Purpose

These guardrails enforce enterprise-grade security standards across the Open AI-USSD Kernel Engine, enabling tenant applications to achieve compliance with PCI DSS, GDPR, ISO 27001, and Zimbabwe Data Protection Act requirements.

---

## 2. Security Guardrails

### GL-SEC-001: Tenant Isolation (RLS Mandatory)

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Every database query must set `app.current_tenant` and use Row-Level Security policies defined in the ledger migrations. |
| **Rationale** | Prevents cross-tenant data leakage, ensures data privacy compliance. |
| **Enforcement** | • All tables have RLS enabled with FORCE.<br>• Go orchestrator sets `app.current_application_id` before queries.<br>• Audit logs verify RLS policy application. |
| **Violation Effect** | Data breach, GDPR violations, regulatory penalties. |

**Implementation (from V073__security_hardening_rls.sql):**
```sql
ALTER TABLE core.transaction_log FORCE ROW LEVEL SECURITY;

CREATE POLICY transaction_log_app_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );
```

---

### GL-SEC-002: mTLS Everywhere

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All gRPC and HTTP traffic between services must use mutual TLS with short-lived certificates (cert-manager + Istio or Linkerd). |
| **Rationale** | Prevents man-in-the-middle attacks, ensures service identity. |
| **Enforcement** | • Cert-manager provisions certificates.<br>• Istio/Linkerd enforces mTLS policy.<br>• Network policies block non-mTLS traffic. |
| **Violation Effect** | Service impersonation, data interception. |

**Certificate Configuration:**
```yaml
# cert-manager Certificate resource
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ussd-kernel-tls
spec:
  secretName: ussd-kernel-tls-secret
  duration: 2160h  # 90 days
  renewBefore: 360h  # 15 days
  subject:
    organizations:
      - OpenAI-USSD-Kernel
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
    - client auth
  dnsNames:
    - orchestrator.ussd-kernel.svc.cluster.local
    - payment-engine.ussd-kernel.svc.cluster.local
```

---

### GL-SEC-003: Secrets Never in Environment Variables

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All API keys (EcoCash, OneMoney, Telecash, Africa's Talking, Vault) must be injected via HashiCorp Vault CSI driver as files (never `env`). |
| **Rationale** | Environment variables are leaked in logs and debugging tools. Vault provides audit and rotation. |
| **Enforcement** | • `pre-commit` hook scans for hardcoded secrets.<br>• Kubernetes Secrets only via CSI driver.<br>• Secret rotation every 90 days. |
| **Violation Effect** | Immediate rejection of deployment. |

**Vault CSI Integration:**
```yaml
# Pod spec with Vault CSI driver
volumes:
  - name: vault-secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: ussd-kernel-secrets

volumeMounts:
  - name: vault-secrets
    mountPath: /mnt/secrets
    readOnly: true
```

---

### GL-SEC-004: PII Encryption at Rest

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All PII (MSISDN, account numbers, names) must be encrypted at rest using AES-256-GCM. MSISDN must be hashed for lookups. |
| **Rationale** | GDPR/Zimbabwe Data Protection Act compliance, prevents data exposure in backups. |
| **Enforcement** | • `ussd.encrypt_msisdn()` trigger auto-encrypts.<br>• `msisdn_hash` used for lookups.<br>• Encryption key from Vault/KMS. |
| **Violation Effect** | Regulatory non-compliance, data breach liability. |

**Implementation (from V043__ussd_session_state.sql):**
```sql
-- Function: Encrypt MSISDN
CREATE OR REPLACE FUNCTION ussd.encrypt_msisdn(
    p_msisdn VARCHAR(20),
    p_key_id VARCHAR(100) DEFAULT 'default'
) RETURNS BYTEA AS $$
DECLARE
    v_key TEXT;
BEGIN
    -- Retrieve encryption key from KMS/Vault
    v_key := COALESCE(
        current_setting('kms.dek_key', true)::text,
        'PRODUCTION_KEY_REQUIRED'
    );
    
    IF v_key = 'PRODUCTION_KEY_REQUIRED' THEN
        RAISE EXCEPTION 'Production encryption key not configured.';
    END IF;
    
    RETURN pgp_sym_encrypt(
        p_msisdn, 
        v_key,
        'cipher-algo=aes256, compress-algo=0'
    )::bytea;
END;
$$ LANGUAGE plpgsql;

-- Trigger: Auto-encrypt on insert
CREATE TRIGGER trg_ussd_sessions_encrypt
    BEFORE INSERT ON ussd.ussd_sessions
    FOR EACH ROW
    EXECUTE FUNCTION ussd.trigger_encrypt_msisdn();
```

---

### GL-SEC-005: PIN/Password Never Logged

| Attribute | Specification |
|-----------|---------------|
| **Statement** | PINs, passwords, and OTPs must never be logged in any form (plaintext, hashed, or encrypted). |
| **Rationale** | PCI DSS requirement, prevents credential exposure in logs. |
| **Enforcement** | • Code review verifies no PIN logging.<br>• Log sanitization filters sensitive fields.<br>• Audit checks for PIN in logs. |
| **Violation Effect** | PCI DSS violation, credential compromise. |

**Implementation:**
```python
# Python Gateway - PIN sanitization
import re

SENSITIVE_PATTERNS = [
    r'pin[=:]\s*\d+',
    r'password[=:]\s*\S+',
    r'otp[=:]\s*\d+',
]

def sanitize_log_message(message: str) -> str:
    for pattern in SENSITIVE_PATTERNS:
        message = re.sub(pattern, '[REDACTED]', message, flags=re.IGNORECASE)
    return message
```

---

### GL-SEC-006: Session Timeout Enforcement

| Attribute | Specification |
|-----------|---------------|
| **Statement** | USSD sessions must enforce multi-layer timeouts: Network (2 min), Application (5 min), Absolute (15 min). |
| **Rationale** | Prevents session hijacking, reduces attack window. |
| **Enforcement** | • Database-level timeout columns.<br>• Cron job marks expired sessions.<br>• Go orchestrator rejects expired session IDs. |
| **Violation Effect** | Session hijacking, unauthorized access. |

**Implementation (from V043__ussd_session_state.sql):**
```sql
-- Multi-layer Timeout Management
network_timeout_at      TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '2 minutes'),
application_timeout_at  TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '5 minutes'),
absolute_timeout_at     TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '15 minutes'),

-- Cleanup function
CREATE OR REPLACE FUNCTION ussd.cleanup_expired_sessions()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE ussd.ussd_sessions
    SET status = 'TIMEOUT',
        termination_reason = 'AUTO_TIMEOUT',
        ended_at = now()
    WHERE status = 'ACTIVE'
      AND application_timeout_at < now();
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;
```

---

### GL-SEC-007: Rate Limiting & DDoS Protection

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All endpoints must implement rate limiting: 10 req/sec per phone number, 100 req/sec per tenant. |
| **Rationale** | Prevents abuse, ensures fair resource allocation. |
| **Enforcement** | • Redis-based token bucket.<br>• Go orchestrator enforces limits.<br>• Africa's Talking rate limits as backup. |
| **Violation Effect** | Service degradation, tenant isolation breach. |

**Implementation:**
```go
// Go Orchestrator - Rate limiting
package middleware

import (
    "context"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type RateLimiter struct {
    redis *redis.Client
}

func (rl *RateLimiter) Allow(ctx context.Context, key string, limit int, window time.Duration) bool {
    pipe := rl.redis.Pipeline()
    now := time.Now().Unix()
    windowStart := now - int64(window.Seconds())
    
    // Remove old entries
    pipe.ZRemRangeByScore(ctx, key, "0", strconv.FormatInt(windowStart, 10))
    
    // Count current entries
    countCmd := pipe.ZCard(ctx, key)
    
    // Add current request
    pipe.ZAdd(ctx, key, &redis.Z{Score: float64(now), Member: now})
    pipe.Expire(ctx, key, window)
    
    pipe.Exec(ctx)
    
    return countCmd.Val() < int64(limit)
}
```

---

### GL-SEC-008: Fraud Detection Integration

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All transactions must be scored for fraud risk (0-100). Suspicious activity must trigger alerts. |
| **Rationale** | Early detection of fraudulent patterns, protection for users and tenants. |
| **Enforcement** | • Fraud score computed on each transaction.<br>• Threshold-based alerting.<br>• Velocity checks for rapid transactions. |
| **Violation Effect** | Undetected fraud, financial losses. |

**Implementation (from V043__ussd_session_state.sql):**
```sql
-- Fraud detection fields
fraud_score             INTEGER DEFAULT 0 CHECK (fraud_score >= 0 AND fraud_score <= 100),
velocity_flags          JSONB DEFAULT '{}',
is_suspicious           BOOLEAN DEFAULT false,
suspicion_reason        TEXT,

-- Velocity check function
CREATE OR REPLACE FUNCTION ussd.check_velocity(
    p_msisdn_hash VARCHAR(64),
    p_time_window INTERVAL DEFAULT interval '1 hour'
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM ussd.ussd_sessions
    WHERE msisdn_hash = p_msisdn_hash
      AND created_at > now() - p_time_window;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;
```

---

### GL-SEC-009: API Key Rotation

| Attribute | Specification |
|-----------|---------------|
| **Statement** | API keys for Africa's Talking and mobile money providers must be rotated every 90 days. |
| **Rationale** | Limits exposure window of compromised credentials. |
| **Enforcement** | • Vault automatically rotates keys.<br>• Alert 15 days before expiration.<br>• Zero-downtime rotation. |
| **Violation Effect** | Stale credentials, potential unauthorized access. |

---

### GL-SEC-010: Audit Trail Completeness

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All security-relevant events must be logged to `audit.session_log` and `audit.change_log` with hash chain integrity. |
| **Rationale** | Forensic analysis, regulatory compliance, incident response. |
| **Enforcement** | • Triggers auto-log all DML operations.<br>• Security events logged explicitly.<br>• Logs immutable (WORM). |
| **Violation Effect** | Incomplete audit trail, compliance violations. |

---

## 3. Security Event Types

```protobuf
// Security events to be logged
enum SecurityEventType {
    AUTHENTICATION_SUCCESS = 0;
    AUTHENTICATION_FAILURE = 1;
    AUTHORIZATION_FAILURE = 2;
    SESSION_CREATED = 3;
    SESSION_TERMINATED = 4;
    SESSION_TIMEOUT = 5;
    FRAUD_ALERT = 6;
    RATE_LIMIT_EXCEEDED = 7;
    SUSPICIOUS_ACTIVITY = 8;
    DATA_EXPORT = 9;
    ANONYMIZATION_EXECUTED = 10;
}
```

---

## 4. Compliance Mapping

| Requirement | Implementation | Verification |
|-------------|----------------|--------------|
| PCI DSS 10.1 | `audit.change_log` with hash chain | Audit query |
| PCI DSS 10.2 | User identification in audit logs | Log inspection |
| PCI DSS 10.3 | Date/time, origin, outcome in logs | Schema validation |
| PCI DSS 11.5 | Hash chain integrity verification | `integrity.compute_batch_hash()` |
| GDPR Art 17 | `core.anonymize_user_data()` function | Function test |
| GDPR Art 32 | Encryption, RLS, audit trails | Security scan |
| ISO 27001 A.12.4 | Comprehensive audit logging | Audit review |
| ISO 27001 A.9.4 | RLS policies, access controls | Policy inspection |

---

## 5. Security Checklist

```markdown
## Security Guardrails Checklist

- [ ] GL-SEC-001: RLS policies applied and FORCE enabled
- [ ] GL-SEC-002: mTLS configured for all inter-service communication
- [ ] GL-SEC-003: Secrets injected via Vault CSI driver
- [ ] GL-SEC-004: PII encrypted at rest with AES-256-GCM
- [ ] GL-SEC-005: No PIN/password logging in code
- [ ] GL-SEC-006: Session timeouts enforced (2/5/15 min)
- [ ] GL-SEC-007: Rate limiting implemented (10/100 req/sec)
- [ ] GL-SEC-008: Fraud scoring integrated
- [ ] GL-SEC-009: API key rotation scheduled (90 days)
- [ ] GL-SEC-010: Audit trail triggers enabled
```
