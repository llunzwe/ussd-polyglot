# Security Hardening Checklist

## Overview

This checklist tracks the implementation status of security controls for the Open AI-USSD Kernel Engine, a USSD kernel providing secure SDK and API endpoints for tenant applications, including mobile money integrations.

## Authentication & Authorization

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| API key SHA-256 hashing | ✅ | `app.api_keys.api_key_hash` | Keys never stored in plaintext |
| API key expiry & revocation | ✅ | `expires_at`, `revoked_at` columns | Automated cleanup via cron |
| API key permissions (RBAC) | ✅ | `permissions TEXT[]` | `read`, `write`, `admin`, `webhook` |
| API key rate limiting tiers | ✅ | `rate_limit_tier` | `free` / `standard` / `premium` |
| Tenant isolation (RLS) | ✅ | `app.current_tenant_id` / `app.current_application_id` | Set on every DB connection |
| Admin-only tables | ✅ | `USING (FALSE)` policies | `ops.*`, `events.cdc_topics` |
| Role-based DB access | ✅ | `app_user`, `ussd_kernel_role`, `admin_role` | Least privilege per schema |

## Cryptography

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Ed25519 batch hash signing | ✅ | `audit/src/infrastructure/signing.rs` | Regulatory requirement (RBZ) |
| Hash chain on transaction_log | ✅ | `record_hash` + `previous_hash` | WORM-protected |
| MSISDN encryption at rest | ✅ | `pgp_sym_encrypt` in `ussd.ussd_sessions` | AES-256-GCM |
| PCI DSS tokenization | ✅ | `core.card_tokens` | No raw PAN storage |
| mTLS on gRPC | ⚠️ | Config exists, certs from Vault CSI | Pending cert-manager deployment |
| HSM integration | ❌ | — | Roadmap Q3 2026 |

## Input Validation & Sanitization

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Proto-level validation | ✅ | `buf lint` + `protoc-gen-validate` | Enforced in CI |
| Phone number validation | ✅ | Tenant-configurable regex in `app.application_registry.configuration` | Default: `^2637[1378]\d{8}$` |
| Africa's Talking signature | ✅ | `ATSignatureValidator` (HMAC-SHA256) | Every webhook validated |
| SQL injection prevention | ✅ | Parameterized queries in all services | sqlx, pgx, psycopg2 |
| PII redaction | ⚠️ | Dictionary-based + ONNX NER model | ML model deployment pending |
| XSS prevention | ✅ | FastAPI auto-escaping | REST API only |

## Audit & Compliance

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Immutable event store | ✅ | `events.event_store` with WORM triggers | Go Orchestrator sole writer |
| Immutable transaction log | ✅ | `core.transaction_log` with WORM triggers | Hash-chained |
| Daily Merkle root | ✅ | `integrity.batch_hashes` | Ed25519-signed |
| Change log | ✅ | `audit.change_log` | Every DDL change tracked |
| Session audit log | ✅ | `audit.session_log` | Encrypted MSISDN |
| Security hardening log | ✅ | `audit.security_hardening_log` | Retroactive RLS tracking |
| RBZ reporting | ⚠️ | Suspense aging reports, delivery receipts | Automated generation pending |

## Infrastructure Security

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Vault CSI for secrets | ❌ | Env vars used currently | Deployment pending |
| Network policies (K8s) | ⚠️ | Baseline policies defined | Full zero-trust pending |
| Pod security standards | ⚠️ | `restricted` profile targeted | Some containers need tuning |
| Image scanning (Trivy) | ✅ | CI integration | HIGH/CRITICAL fail build |
| Secret scanning (TruffleHog) | ✅ | CI integration | Weekly scheduled scan |
| Dependency audit | ⚠️ | cargo-audit, govulncheck, safety | Manual execution; CI pending |
| DDoS protection | ⚠️ | Cloudflare / AWS Shield | Configured at edge |

## CI/CD Security

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Signed commits | ⚠️ | Encouraged, not enforced | GPG signing policy pending |
| SAST in CI | ⚠️ | golangci-lint, ruff, clippy | Bandit, cargo-audit pending |
| Container scanning | ✅ | Trivy in CI | All images scanned |
| SBOM generation | ❌ | — | Syft/SPDX roadmap |
| Deployment approval | ❌ | — | GitOps with ArgoCD planned |

## Incident Response

| Control | Status | Implementation | Notes |
|---------|--------|----------------|-------|
| Security incident playbook | ⚠️ | Draft exists | Needs RBZ alignment |
| Automated alerting | ✅ | Prometheus + Alertmanager | PagerDuty integration |
| Forensic logging | ✅ | All events to `events.event_store` | 7-year retention |
| Data breach notification | ⚠️ | 72-hour RBZ notification procedure | Documented, untested |

## Gap Summary

### Critical (Fix Before Production)

1. **Vault CSI deployment** — Replace all env-var secrets with Vault-injected files
2. **mTLS certificate rotation** — Automate with cert-manager
3. **HSM for signing keys** — Ed25519 keys must be HSM-protected for RBZ compliance

### High (Fix Within 30 Days)

4. **Network policies** — Implement zero-trust K8s network policies
5. **Pod security standards** — Enforce `restricted` profile
6. **SBOM generation** — Generate SPDX SBOMs for all releases
7. **Deployment approval gates** — GitOps with manual approval for production

### Medium (Fix Within 90 Days)

8. **GPG signed commits** — Enforce via branch protection
9. **SAST automation** — Integrate Bandit, Semgrep, cargo-audit in CI
10. **DLP for PII** — Implement data loss prevention on outbound traffic
11. **Penetration testing** — Annual third-party pentest

## Compliance Mapping

| Requirement | RBZ | POTRAZ | PCI DSS | Implementation |
|-------------|-----|--------|---------|----------------|
| Transaction immutability | ✅ | ✅ | — | WORM triggers |
| Hash chain integrity | ✅ | — | — | SHA-256 chain |
| Daily signed audit | ✅ | — | — | Ed25519 Merkle root |
| MSISDN encryption | — | ✅ | — | AES-256-GCM |
| PAN tokenization | — | — | ✅ | SHA-256 + token vault |
| 7-year retention | ✅ | ✅ | — | TimescaleDB |
| Access logging | ✅ | — | ✅ | `api.access_audit_log` |
| Incident notification | ✅ | ✅ | — | 72-hour procedure |
