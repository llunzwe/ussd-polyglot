# RBAC Matrix

This document defines roles and permissions across the Open AI-USSD Kernel platform.

## Roles

| Role | Description |
|------|-------------|
| `platform-admin` | Full control over infrastructure, deployments, secrets, and tenant onboarding. |
| `tenant-developer` | Can manage tenant-specific configurations, provider credentials, and view tenant-scoped metrics. |
| `ops-readonly` | Read-only access to logs, metrics, deployments, and events for incident response. |
| `security-auditor` | Access to audit logs, security scan results, and policies; cannot modify workloads. |

## Kubernetes RBAC

### platform-admin

- **Namespaces**: All (`*`)
- **Resources**: All (`*`)
- **Verbs**: `*`

### tenant-developer

- **Namespaces**: `open-ai-ussd-kernel`, `open-ai-ussd-kernel-staging`
- **Resources**: `configmaps`, `deployments`, `services`, `ingresses`, `secrets` (tenant-scoped only)
- **Verbs**: `get`, `list`, `watch`, `create`, `update`, `patch`
- **Restrictions**: Cannot access `postgres-credentials` or `payment-engine-secret` cluster-wide secrets.

### ops-readonly

- **Namespaces**: All platform namespaces
- **Resources**: `pods`, `pods/log`, `services`, `deployments`, `events`, `configmaps`, `hpa`, `nodes`
- **Verbs**: `get`, `list`, `watch`

### security-auditor

- **Namespaces**: All platform namespaces
- **Resources**: `networkpolicies`, `podsecuritypolicies`, `roles`, `rolebindings`, `secrets` (read-only for metadata), `events`, `pods`
- **Verbs**: `get`, `list`, `watch`

## Application-Level Permissions

| Permission | platform-admin | tenant-developer | ops-readonly | security-auditor |
|------------|:------------:|:----------------:|:------------:|:----------------:|
| Create tenant | ✅ | ❌ | ❌ | ❌ |
| Update tenant config | ✅ | ✅ (own) | ❌ | ❌ |
| View tenant events | ✅ | ✅ (own) | ✅ | ✅ |
| Replay events | ✅ | ❌ | ❌ | ❌ |
| Rotate provider credentials | ✅ | ✅ (own) | ❌ | ❌ |
| View system metrics | ✅ | ✅ | ✅ | ✅ |
| View audit logs | ✅ | ❌ | ✅ | ✅ |
| Trigger deployment | ✅ | ❌ | ❌ | ❌ |
| Read secrets content | ✅ | ❌ | ❌ | ✅ (audit only) |
