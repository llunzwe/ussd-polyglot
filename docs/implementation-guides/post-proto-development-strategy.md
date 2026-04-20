# Post-Proto Development Strategy

**Version**: 1.0.0  
**Status**: Approved  
**Last Updated**: 2026-04-13  
**Author**: Architecture Team  

---

## Executive Summary

This document defines the precise engineering sequence for advancing the Open AI-USSD Kernel Engine **after** the completion of the protobuf domain contracts (V001–V073 aligned) and the generation of language-specific stubs across Go, Python, and Rust.

The current state represents the **contract-complete inflection point**. All 14 bounded contexts have been defined, all gRPC services have been specified, and all three language runtimes can successfully compile against the generated stubs. However, the stubs are merely **interface contracts**—they contain no business logic, no state machines, and no ledger integration.

The next phase must follow strict dependency order: **Rust Foundation → Go Orchestration → Python Intelligence**. Deviating from this sequence introduces speculative integration risk, mock-driven development anti-patterns, and architectural debt that will compound as the system approaches production.

---

## 1. The Contract-Complete Inflection Point

### 1.1 What Has Been Achieved

| Deliverable | Status | Verification |
|-------------|--------|--------------|
| 14 enterprise-grade `.proto` files | ✅ Complete | `buf lint` passes |
| Go stubs (28 files) | ✅ Complete | `go build ./...` passes |
| Python stubs (42+ files) | ✅ Complete | Import verification passes |
| Rust stubs (14 domains via `tonic_build`) | ✅ Complete | `cargo build --workspace` passes |
| CI pipeline (`proto-ci.yml`) | ✅ Complete | 4-stage pipeline active |

### 1.2 What the Stubs Actually Are

The generated stubs are **immutable interface artifacts**, not applications. They provide:

- **Serialization/deserialization** logic for protobuf messages.
- **gRPC server traits** (e.g., `PaymentEngine`, `SessionReconstructor`) that must be implemented.
- **gRPC client stubs** for cross-service communication.

They do **not** provide:
- Business logic or domain state machines.
- Database connectivity or query patterns.
- Provider integrations (EcoCash, OneMoney, Telecash).
- Security controls, rate limiting, or observability.

### 1.3 The Danger of Skipping the Foundation

Building the Go Orchestrator or Python Gateway before the Rust engines forces those teams to code against **unverified contracts**. When the Rust engines are finally built, inevitable mismatches in field semantics, latency assumptions, or error-handling patterns will cascade into expensive rework. The enterprise-grade approach is to **fulfill the contract from the database upward**.

---

## 2. Phase 1: Build the Rust Foundation Engines (M1)

### 2.1 Why Rust Must Come First

The architecture is strictly layered:

```
Python Gateway → Go Orchestrator → Rust Engines → PostgreSQL Ledger
```

Rust sits at the **critical path** of every high-value operation:

- **Session reconstruction**: Required for every USSD request.
- **Payment initiation**: Required for every financial transaction.
- **Hash-chain verification**: Required for tamper-evident auditability.

By implementing Rust first:

1. **Proto contracts are validated in steel** — serialization assumptions, field defaults, and error mappings are proven against real behavior.
2. **Ledger read/write patterns are canonicalized** — the query shapes, index usage, and transaction boundaries that Rust defines become the reference implementation for Go.
3. **Integration testing begins on day one** — when the Go team starts M2, they have real, callable gRPC endpoints rather than `UNIMPLEMENTED` status codes.

### 2.2 Engine A: Session Reconstructor

**Service**: `rust-engine/session-reconstructor`  
**Proto Contract**: `ussd.v1.session.SessionReconstructor`  
**Critical Success Factor**: Rebuild session state in `< 1ms` P99.

#### 2.2.1 Domain Layer (`src/domain/`)

Implement a **pure state-fold function** that is deterministic, side-effect-free, and testable:

```rust
// Conceptual signature
pub fn fold_session_state(events: Vec<EventEnvelope>) -> Result<SessionState, IntegrityError>
```

The fold must:
- Apply events in strict `version` order.
- Maintain a `HashMap<String, String>` representing the user's session variables.
- Verify the hash chain: `SHA-256(previous_hash || payload || occurred_at) == record_hash`.
- Support idempotent replays (folding the same event stream twice yields identical state).

**Domain errors to define**:
- `SessionNotFound`: No events exist for the requested `session_id`.
- `EventSequenceGap`: Missing version numbers in the event stream.
- `HashMismatch`: Computed hash does not match `record_hash`.
- `InvalidEventType`: Unknown event type in the stream.

#### 2.2.2 Application Layer (`src/application/`)

| Handler | Responsibility |
|---------|----------------|
| `ReconstructSessionHandler` | Query `events.event_store` by `stream_id`, apply fold, return `ReconstructSessionResponse`. |
| `VerifyIntegrityHandler` | Recompute the entire hash chain and verify `previous_hash` linkage. |
| `CreateCheckpointHandler` | Persist a materialized snapshot of session state for fast recovery. |

**Query Pattern**:
```sql
SELECT event_id, event_type, version, payload, record_hash, previous_hash, occurred_at
FROM events.event_store
WHERE stream_id = $1
ORDER BY version ASC
LIMIT $2;
```

The query must use the composite index on `(stream_id, version)` to guarantee `< 1ms` latency.

#### 2.2.3 Infrastructure Layer (`src/infrastructure/`)

**PostgreSQL Adapter**:
- Use `sqlx` with prepared statements.
- Enforce tenant isolation via `SET app.current_tenant_id = ?` before every query.
- Connection pooling: max 25 connections per instance, align with PgBouncer if used.

**Cache**:
- Implement an LRU cache (`moka` or `dashmap`) for hot sessions.
- Cache key: `(tenant_id, session_id)`.
- TTL: 180 seconds (matching Africa's Talking session timeout).
- Cache invalidation on `SessionEndedEvent`.

**Circuit Breaker**:
- If DB latency exceeds 500ms for 5 consecutive requests, fail fast with `Status::unavailable`.
- Half-open state: allow 1 probe request every 10 seconds.

#### 2.2.4 gRPC Adapter (`src/ports/grpc.rs`)

- Implement `tonic::SessionReconstructor` for all RPCs:
  - `ReconstructSession`
  - `ReconstructSessions` (bidirectional streaming)
  - `VerifySessionIntegrity`
  - `GetIntegrityProof`
  - `CreateCheckpoint`
  - `Health`

- Map domain errors precisely:
  - `SessionNotFound` → `tonic::Code::NotFound`
  - `HashMismatch` → `tonic::Code::FailedPrecondition`
  - `EventSequenceGap` → `tonic::Code::DataLoss`

- Propagate OpenTelemetry trace context from the protobuf `TracingContext` into every span.

#### 2.2.5 Success Criteria

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Reconstruction latency (P99) | `< 1ms` | Prometheus histogram for 50-event replay |
| Hash verification | `100%` | Automated integration test on every build |
| Concurrent sessions | `10,000` | Load test with `k6` or `locust` via gRPC |
| Memory usage | `< 100MB` | `heaptrack` or Kubernetes metrics |

---

### 2.3 Engine B: Payment Engine

**Service**: `rust-engine/payment-engine`  
**Proto Contract**: `ussd.v1.payment.PaymentEngine`  
**Critical Success Factor**: Zero duplicate payments under any failure mode.

#### 2.3.1 Domain Layer (`src/domain/`)

Implement the `Payment` aggregate as a **finite state machine**:

```
Pending → Processing → (Completed | Failed | Cancelled | Refunded)
```

State transitions must be **validated** — e.g., `Completed` cannot transition to `Pending`.

**Idempotency Guard**:
- The `idempotency_key` (tenant-provided) is the primary deduplication key.
- Before creating a new payment, query `core.transaction_log` for an existing record with the same key.
- If found, return the existing payment status and provider reference without calling the mobile money provider.

**Validation Rules**:
- Phone number must match Zimbabwe format: `^2637[1378]\d{8}$`.
- Amount must be `> 0` and `< 1,000,000,000` cents (ZWL) or equivalent.
- Reference must be non-empty and `≤ 100` characters.

#### 2.3.2 Application Layer (`src/application/`)

| Handler | Responsibility |
|---------|----------------|
| `InitiatePaymentHandler` | Validate, check idempotency, call provider, persist result. |
| `ProcessCallbackHandler` | Verify HMAC signature, update payment state, trigger reconciliation. |
| `GetPaymentStatusHandler` | Query local state or provider API for current status. |
| `RefundPaymentHandler` | Initiate reversal if provider supports it. |

**Retry Policy**:
- **Only idempotent HTTP calls may be retried** (e.g., `GET /transaction/{id}`).
- **Non-idempotent calls** (`POST /payment`) must never be blindly retried.
- Exponential backoff: `base * 2^(attempt-1) + jitter` where base = 1 second.
- Max attempts: 3.

#### 2.3.3 Infrastructure Layer (`src/infrastructure/`)

**Provider Adapters**:

| Provider | Protocol | Authentication |
|----------|----------|----------------|
| EcoCash | HTTPS/JSON | HMAC-SHA256 (`X-Signature` header) |
| OneMoney | HTTPS/JSON | API Key + Bearer Token |
| Telecash | HTTPS/JSON or SOAP | API Key + Client Certificate |

Each adapter must:
- Implement the `MobileMoneyProviderClient` trait.
- Use `reqwest` with a 30-second timeout.
- Log structured events: `payment_initiated`, `provider_response_received`, `callback_processed`.
- Emit Prometheus metrics: `provider_request_duration_seconds{provider="ecocash",status="200"}`.

**Secret Management**:
- Fetch credentials from HashiCorp Vault at startup.
- Reload credentials every 15 minutes without restarting the service.
- Never log API keys or merchant secrets.

#### 2.3.4 The Outbox Pattern (Critical)

The architecture states that **Go is the sole writer to the immutable ledger**. However, the Payment Engine must record `PaymentInitiated` events. To resolve this tension without creating a circular gRPC dependency (Rust → Go → Rust), the enterprise-grade solution is the **Outbox Pattern**:

1. Rust writes payment events to a local `outbox` table in the same PostgreSQL transaction as the provider acknowledgment.
2. The Go Orchestrator (or a dedicated relay service) polls the `outbox` table.
3. The relay reads unprocessed rows, calls `AppendEvent` to write them to `events.event_store`, then marks them as processed.
4. This preserves the "single writer" principle while giving Rust autonomy.

**Schema**:
```sql
CREATE TABLE payment_engine.outbox (
    outbox_id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    aggregate_id UUID NOT NULL,
    idempotency_key VARCHAR(255) NOT NULL,
    occurred_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    processed_by VARCHAR(100)
);
```

#### 2.3.5 gRPC Adapter (`src/ports/grpc.rs`)

Implement the full `PaymentEngine` tonic trait including:
- `InitiatePayment`
- `InitiateDisbursement`
- `BulkInitiatePayment`
- `RefundPayment`
- `GetPaymentStatus`
- `ProcessCallback`
- `GetProviderBalance`
- `GetProviderCapabilities`
- `Health`

Map domain errors to gRPC status codes with full protobuf `Error` payloads.

#### 2.3.6 Success Criteria

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Payment initiation latency | `< 500ms` (internal) | Prometheus histogram |
| Provider response latency | `< 2s` | External API timing |
| Retry success rate | `99.5%` | After 3 attempts |
| Duplicate payment rate | `0%` | Chaos test with 100K duplicates |
| Callback processing | `< 100ms` | End-to-end from webhook to ledger |
| Throughput | `1,000 TPS` | Sustained load test |

---

## 3. Enterprise-Grade Development Methodology

### 3.1 Test Pyramid (Heavy Base)

```
        ▲
       /_\   E2E / Chaos (1%)
      /___\  Contract Tests (10%)
     /_____\ Integration Tests (30%)
    /_______\ Unit Tests (60%)
```

| Test Type | Scope | Target | Tools |
|-----------|-------|--------|-------|
| **Unit** | Pure domain logic (state folds, validation, status transitions) | `≥ 90%` | Rust built-in + `mockall` |
| **Integration** | DB adapters with real PostgreSQL | `≥ 80%` | `sqlx` + `testcontainers` |
| **Contract** | gRPC roundtrips using generated stubs | `100%` of RPCs | In-memory `tonic` server |
| **Chaos** | Network partitions, DB failures, provider timeouts | Critical paths | `toxiproxy-rs`, custom fault injection |

**Rule**: No gRPC handler is merged without a passing contract test that exercises both success and error paths.

### 3.2 Observability-First

Every engine must emit three signals:

**Metrics (Prometheus)**:
```rust
// Examples
session_reconstructed_duration_seconds
session_reconstruct_errors_total{reason="hash_mismatch"}
payment_initiated_total{provider="ecocash",status="success"}
provider_request_duration_seconds{provider="ecocash"}
```

**Traces (OpenTelemetry)**:
- Extract `trace_id` and `span_id` from the protobuf `TracingContext`.
- Create child spans for every DB query and HTTP provider call.
- Propagate trace context across service boundaries.

**Logs (Structured JSON)**:
```json
{
  "timestamp": "2026-04-13T14:30:00Z",
  "level": "INFO",
  "message": "Payment initiated",
  "trace_id": "abc123",
  "span_id": "def456",
  "payment_id": "uuid-here",
  "tenant_id": "tenant-uuid",
  "provider": "ecocash"
}
```

### 3.3 Security by Design

1. **Secrets Management**: No hardcoded keys. Use Vault CSI or file-mounted secrets read at startup.
2. **Encryption at Rest**: MSISDNs encrypted via `pgcrypto` before storage (aligned with `core.encrypted_fields`).
3. **Transport Security**: All gRPC uses **mTLS** (mutual TLS), not just server-side TLS.
4. **Row-Level Security**: Every SQL query sets `app.current_tenant_id` before accessing tenant-scoped tables.
5. **Input Validation**: Reject malformed phone numbers and amounts at the domain layer before any external call.

### 3.4 Anti-Corruption Layers

**Never** let generated protobuf structs leak into domain logic. Use explicit mappers:

```rust
// enterprise standard
pub fn proto_to_domain(req: InitiatePaymentRequest) -> Result<Payment, DomainError> { ... }
pub fn domain_to_proto(payment: Payment) -> InitiatePaymentResponse { ... }
```

This insulates the domain from proto churn. When the proto changes, you update one mapper file, not 50 domain functions.

---

## 4. Phase 2: Go Orchestrator (M2)

Only after the Rust engines pass their M1 success criteria does M2 begin.

### 4.1 What Makes M2 Possible

The Go team can now code against **real gRPC endpoints**:
- `SessionReconstructor.ReconstructSession()` returns real session state.
- `PaymentEngine.InitiatePayment()` moves real money (in sandbox).
- `AppendEvent` can be tested with real event sequences from Rust.

### 4.2 Core Components to Build

| Component | Responsibility |
|-----------|----------------|
| **Tenant Router** | Maps USSD shortcodes (`*123*1#`) to tenant gRPC endpoints. |
| **Event Writer** | Sole authority for `AppendEvent` using serializable transactions and optimistic concurrency control. |
| **Rate Limiter** | Token-bucket per phone number and per tenant, backed by Redis. |
| **Saga Orchestrator** | Coordinates multi-step flows with compensation logic (e.g., refund on failure). |
| **gRPC Gateway** | Exposes `Orchestrator` service to Python and tenant applications. |

### 4.3 Why Go Cannot Be Built First

If Go were built first, the team would be forced to:
- Mock the Rust payment engine's latency and error behavior.
- Guess at the Session Reconstructor's response format.
- Write integration tests that assert against imaginary behavior.

This is **mock-driven development**, a known anti-pattern in distributed systems. It produces code that "passes tests" but fails in production.

---

## 5. Phase 3: Python Gateway & AI Brain (M3)

Only after the Go Orchestrator is stable and callable.

### 5.1 Components to Build

| Component | Responsibility |
|-----------|----------------|
| **USSD Gateway** | Flask/FastAPI handler for Africa's Talking callbacks. |
| **AI Brain** | SLM inference for Shona/Ndebele translation, personalization, intent detection. |
| **Tenant SDK** | Python library with decorators (`@ussd.menu`, `@session.persist`) abstracting gRPC. |

### 5.2 Why Python Must Come Last

The Python gateway is the **user-facing facade**. Building it first creates a fragile UI layer that appears functional but collapses when underlying latency budgets, error codes, or state-machine behaviors change. Enterprise engineering means building from the **kernel outward**.

---

## 6. Critical Architectural Decisions

### 6.1 Decision 1: Rust Writes to Outbox, Go Writes to Ledger

| Option | Description | Verdict |
|--------|-------------|---------|
| **A (Chosen)** | Rust uses local `outbox` table; Go polls and appends to ledger. | ✅ Preserves single-writer principle, avoids circular dependency. |
| B | Rust calls Go's `AppendEvent` gRPC synchronously. | ❌ Creates circular dependency (Go depends on Rust, Rust depends on Go). |
| C | Rust writes directly to ledger. | ❌ Violates architectural governance; Go loses oversight. |

### 6.2 Decision 2: Generated Stubs Are Build Artifacts

| Option | Description | Verdict |
|--------|-------------|---------|
| **A (Chosen)** | Go/Python stubs committed; Rust stubs generated in `OUT_DIR`. | ✅ Aligns with each language's ecosystem conventions. |
| B | All stubs committed. | ❌ Noise in PR reviews; language idioms differ. |
| C | No stubs committed; generate in CI. | ⚠️ Cleaner diffs but requires `protoc` in every build environment. |

### 6.3 Decision 3: Cache Hot Sessions in Rust

| Option | Description | Verdict |
|--------|-------------|---------|
| **A (Chosen)** | LRU cache in `session-reconstructor` for P99 `< 1ms`. | ✅ Justified by read-heavy USSD pattern. |
| B | No cache; always query DB. | ❌ Latency will exceed budget under load. |
| C | Cache in Redis (Go layer). | ❌ Adds network hop; Rust is closer to the ledger. |

---

## 7. Immediate Tactical Action Plan

### Week 1: Rust Foundation Sprint

| Day | Action | Owner | Deliverable |
|-----|--------|-------|-------------|
| **1** | Scaffold `session-reconstructor` domain layer (state fold, errors). | Rust Engineer | Unit tests for fold function. |
| **2** | Implement `sqlx` adapter + `ReconstructSession` gRPC handler. | Rust Engineer | Contract test passing. |
| **3** | Add integrity verification (`VerifySessionIntegrity`) + LRU cache. | Rust Engineer | `< 1ms` latency benchmark. |
| **4** | Scaffold `payment-engine` domain layer (Payment aggregate, provider trait). | Rust Engineer | FSM unit tests passing. |
| **5** | Implement EcoCash adapter + `InitiatePayment` gRPC handler. | Rust Engineer | Sandbox payment succeeds. |
| **6** | Implement outbox pattern + idempotency guard. | Rust Engineer | 0% duplicates under chaos test. |
| **7** | Security review: HMAC verification, secret injection, TLS, SQL audit. | Security Lead | Sign-off document. |

---

## 8. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| **EcoCash API documentation incomplete** | Medium | High | Build adapter against sandbox; harden generic provider trait for rapid adapter swaps. |
| **DB latency > 1ms under load** | Low | High | Composite index on `(stream_id, version)`; load test with `pgbench`; cache hot sessions. |
| **Proto contract churn during Rust build** | Medium | Medium | Weekly proto freeze during engine sprints; use `buf breaking` in CI. |
| **Circular dependency if outbox skipped** | Low | Critical | Enforce ADR-001; code review must verify no direct Rust→Go gRPC calls for ledger writes. |
| **Talent gap in Rust async/Tokio** | Medium | Medium | Pair programming; maintain implementation guides with code samples. |

---

## 9. Definition of Done for M1

M1 is not "code compiles." M1 is **foundation hardened**.

```yaml
ledger:
  migrations_applied: 73
  tables_created: 45
  rls_policies_active: true

rust_session_reconstructor:
  latency_p99: "< 1ms"
  events_replay: 50
  hash_verification: 100%
  contract_tests: 100% passing

rust_payment_engine:
  providers:
    - ecocash
    - onemoney
  idempotency: 100%
  retry_success_rate: 99.5%
  duplicate_payment_rate: 0%
  outbox_pattern: implemented

security:
  tls: mTLS enforced
  secrets: vault-mounted
  sql_injection_audit: passed
  encryption_at_rest: msisdn encrypted

observability:
  metrics: prometheus exported
  traces: opentelemetry wired
  logs: structured json
```

---

## 10. Summary

You have completed the **interface layer**. The next step is the **foundation layer**.

Build the Rust Session Reconstructor and Payment Engine **before** touching the Go Orchestrator or Python Gateway. These two engines define the immutable ledger's read semantics, payment safety, and tamper-evident integrity. Every other layer—the router, the AI, the SDK, the edge nodes—depends on them being fast, correct, and uncompromising.

Do not skip M1 to chase UI features. The immutable ledger is the **highest leverage point** in the entire system. If the Rust engines are weak, the kernel collapses under real money and real users.

> **Build from the ledger upward. Verify in steel before you paint the facade.**
