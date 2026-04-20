# Architectural Guardrails (GL-ARCH-xxx)

**Version**: 1.0.0 (Aligned with Ledger Migrations V001-V073)  
**Status**: Approved for Enterprise Implementation  
**Last Updated**: 2026-04-13  
**Owner**: Architecture Review Board  

---

## 1. Purpose

These guardrails enforce the **Domain-Driven Design + Hexagonal Architecture (Ports & Adapters) + CQRS + Event Sourcing** architecture across the polyglot stack (Python, Go, Rust) while treating the PostgreSQL immutable ledger as the single source of truth and "smart-contract" execution engine.

---

## 2. Core Architectural Guardrails

### GL-ARCH-001: Bounded Context Isolation

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Services may only communicate via published gRPC Protobuf contracts located in `/protos/`. No direct function calls, shared memory, or database access across bounded contexts. |
| **Rationale** | Prevents tight coupling and enables independent scaling, deployment, and technology choices (Python gateway, Go orchestrator, Rust engines). |
| **Enforcement** | • CI pipeline runs `buf lint` + `buf breaking` on every PR.<br>• Rust/Go/Python linters reject any import outside the service's own bounded context.<br>• All inter-service calls must be explicitly declared in `protos/*.proto`. |
| **Violation Effect** | PR automatically blocked. Eventual consistency guarantees break. |

**Implementation Notes:**
```protobuf
// Example: /protos/orchestrator.proto
service Orchestrator {
  rpc AppendEvent (AppendEventRequest) returns (AppendEventResponse);
  rpc RouteToTenant (RouteRequest) returns (RouteResponse);
}
```

---

### GL-ARCH-002: Hexagonal Core Purity

| Attribute | Specification |
|-----------|---------------|
| **Statement** | The **domain** layer of every service must contain **zero** infrastructure imports (no `pgx`, `sqlx`, `reqwest`, `torch`, `redis`, etc.). |
| **Rationale** | Keeps business rules (smart-contract logic) pure, testable, and portable. All I/O lives in adapters. |
| **Enforcement** | • Rust: `clippy` rule + custom `deny(infrastructure_in_domain)`.<br>• Go: `golangci-lint` + custom linter.<br>• Python: `mypy` + `ruff` rule scanning for `from infrastructure import`.<br>• Architecture review checklist required on every PR touching `domain/`. |
| **Violation Effect** | Domain logic becomes untestable and non-deterministic. |

**Hexagonal Structure:**
```
service-name/
├── domain/          # Pure business logic (no imports)
│   ├── aggregate/
│   ├── entity/
│   └── value_object/
├── application/     # Use cases (orchestrates domain)
├── ports/           # Interface definitions
│   ├── inbound/     # Driven by external actors
│   └── outbound/    # Driving external systems
└── adapters/        # Infrastructure implementations
    ├── inbound/     # gRPC/HTTP handlers
    └── outbound/    # DB/Cache/API clients
```

---

### GL-ARCH-003: Ledger as Single Source of Truth (Immutable Smart Contracts)

| Attribute | Specification |
|-----------|---------------|
| **Statement** | **All writes** must go through the Go Orchestrator's `AppendEvent` RPC (never direct SQL `INSERT` from Python or Rust). The immutable ledger (`core.transaction_log`, `events.event_store`, `integrity.*` tables) is the only persistent store. |
| **Rationale** | Guarantees hash-chaining, double-entry accounting, idempotency, and tamper-evidence. Database triggers (`prevent_update`, `prevent_delete`, `prevent_truncate`) act as on-ledger smart-contract enforcement. |
| **Enforcement** | • Go Orchestrator exposes the only PostgreSQL write credentials.<br>• Rust Payment Engine and Session Reconstructor call `AppendEvent` via gRPC.<br>• Python Gateway never imports `psycopg`.<br>• Integration tests use Testcontainers to verify trigger enforcement. |
| **Violation Effect** | Immediate security incident + regulatory non-compliance. |

**Database-Level Enforcement (from V001-V073 migrations):**
```sql
-- From V002__core_utilities.sql
CREATE OR REPLACE FUNCTION core.prevent_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Updates not allowed on immutable table: %. Use soft-delete or create new record.', TG_TABLE_NAME;
END;
$$;

-- Applied to core.transaction_log, core.movement_legs, core.movement_postings
-- From V006__core_transaction_log.sql
CREATE TRIGGER trg_transaction_log_prevent_update
    BEFORE UPDATE ON core.transaction_log
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_update();
```

---

### GL-ARCH-004: CQRS Strict Separation

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Command side (writes) only appends events to the ledger. Query side uses materialized views, projections, or Rust in-memory replay. No service may read and write in the same transaction. |
| **Rationale** | Enables low-latency session reconstruction (<1 ms) and AI training on read models without blocking the write path. |
| **Enforcement** | Code review + static analysis flags any query inside a command handler. |
| **Violation Effect** | Deadlocks, performance degradation, consistency violations. |

**CQRS Flow:**
```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Command Side  │────▶│  Immutable Ledger │────▶│   Query Side    │
│  (Go Orchestrator)│    │  (PostgreSQL)     │     │  (Materialized  │
│                 │     │                   │     │   Views, Redis) │
└─────────────────┘     └──────────────────┘     └─────────────────┘
        │                                              │
        ▼                                              ▼
   Append Event                                  Read Projection
   (core.transaction_log)                        (events.projections)
```

---

### GL-ARCH-005: Event Sourcing Replay Only

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Session state must be derived exclusively by replaying events (Rust Session Reconstructor pure fold function). No in-memory session stores or caches that bypass the ledger. |
| **Rationale** | Enables offline edge reconstruction on Raspberry Pi and perfect auditability. |
| **Enforcement** | Rust `session-reconstructor` crate must export only `ReconstructSession` gRPC method; no public mutable state. |
| **Violation Effect** | State divergence between cloud and edge, audit trail breaks. |

**Event Replay Function (from V043__ussd_session_state.sql):**
```rust
// Rust Session Reconstructor
pub fn reconstruct_session(events: Vec<Event>) -> SessionState {
    events.iter().fold(SessionState::default(), |state, event| {
        match event.event_type {
            EventType::SessionCreated => state.apply_created(event),
            EventType::MenuNavigated => state.apply_navigation(event),
            EventType::InputReceived => state.apply_input(event),
            EventType::PaymentInitiated => state.apply_payment(event),
            _ => state
        }
    })
}
```

---

### GL-ARCH-006: Hash Chain Integrity

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Every ledger entry must include `previous_hash` and `record_hash` forming a cryptographic chain. Batch hashes must be computed daily. |
| **Rationale** | Provides tamper-evident audit trail for regulatory compliance (PCI DSS, SOX, GDPR). |
| **Enforcement** | • Trigger `core.compute_transaction_hash` auto-computes hashes.<br>• Daily cron job calls `integrity.compute_batch_hash()`.<br>• Rust Merkle module verifies batch proofs. |
| **Violation Effect** | Audit findings, regulatory penalties, loss of trust. |

**Hash Chain Implementation (from V006__core_transaction_log.sql):**
```sql
CREATE OR REPLACE FUNCTION core.compute_transaction_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_hash VARCHAR(64);
BEGIN
    -- Get previous hash in chain
    SELECT record_hash INTO v_previous_hash
    FROM core.transaction_log
    ORDER BY chain_sequence DESC NULLS LAST
    LIMIT 1;
    
    NEW.previous_hash := v_previous_hash;
    
    -- Compute SHA-256 hash
    NEW.record_hash := core.generate_row_hash(
        'core.transaction_log',
        NEW.transaction_uuid,
        jsonb_build_object(
            'transaction_type_id', NEW.transaction_type_id,
            'initiator_account_id', NEW.initiator_account_id,
            'amount', NEW.amount,
            'status', NEW.status,
            'idempotency_key', NEW.idempotency_key
        ),
        NEW.committed_at,
        v_previous_hash
    );
    
    RETURN NEW;
END;
$$;
```

---

### GL-ARCH-007: Multi-Tenancy Isolation

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Every tenant's data must be isolated via Row-Level Security (RLS) policies. No cross-tenant data access allowed. |
| **Rationale** | Ensures data privacy, regulatory compliance, and prevents data leakage between tenants. |
| **Enforcement** | • All tables have `application_id` column.<br>• RLS policies enforce `app.current_application_id` check.<br>• Go orchestrator sets tenant context before each query. |
| **Violation Effect** | Data breach, GDPR violations, loss of tenant trust. |

**RLS Policy Example (from V006__core_transaction_log.sql):**
```sql
-- Policy: Application-scoped access
CREATE POLICY transaction_log_app_access ON core.transaction_log
    FOR SELECT
    TO ussd_app_user
    USING (
        application_id = core.get_current_setting_as_uuid('app.current_application_id')
        OR application_id IS NULL
    );
```

---

### GL-ARCH-008: Idempotency Guarantee

| Attribute | Specification |
|-----------|---------------|
| **Statement** | All write operations must be idempotent via `idempotency_key`. Duplicate keys must be rejected with error code `P0002`. |
| **Rationale** | Prevents duplicate payments, double-charging, and data corruption during network retries. |
| **Enforcement** | • Trigger `core.check_idempotency` validates keys.<br>• Mobile money integrations use unique reference fields.<br>• Go orchestrator maintains idempotency cache in Redis. |
| **Violation Effect** | Double payments, customer disputes, financial losses. |

**Idempotency Check (from V006__core_transaction_log.sql):**
```sql
CREATE OR REPLACE FUNCTION core.check_idempotency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing_id BIGINT;
    v_existing_uuid UUID;
    v_existing_status VARCHAR(20);
BEGIN
    -- Check if idempotency key already exists
    SELECT transaction_id, transaction_uuid, status 
    INTO v_existing_id, v_existing_uuid, v_existing_status
    FROM core.transaction_log
    WHERE idempotency_key = NEW.idempotency_key
    LIMIT 1;
    
    IF FOUND THEN
        RAISE EXCEPTION 'IDEMPOTENCY_VIOLATION: Transaction with key % already exists',
            NEW.idempotency_key
            USING ERRCODE = 'P0002';
    END IF;
    
    RETURN NEW;
END;
$$;
```

---

### GL-ARCH-009: Polyglot Language Boundaries

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Each service must be implemented in its designated language: Python (Gateway/AI), Go (Orchestrator), Rust (Mission-critical engines). No mixing within a service. |
| **Rationale** | Leverages each language's strengths; Python for rapid AI development, Go for concurrency, Rust for performance/safety. |
| **Enforcement** | • CI pipeline enforces language-specific builds.<br>• Code review verifies no foreign language imports.<br>• Service boundaries defined in `/protos/`. |
| **Violation Effect** | Performance issues, security vulnerabilities, maintenance nightmare. |

**Language Responsibilities:**

| Component | Language | Responsibility |
|-----------|----------|----------------|
| USSD Gateway | Python | Africa's Talking integration, AI inference, tenant callback handling |
| AI Brain | Python | SLM inference, translation, personalization |
| Orchestrator | Go | Request routing, event appending, tenant management |
| Session Reconstructor | Rust | <1ms event replay, state reconstruction |
| Payment Engine | Rust | Kernel-provided mobile money adapters (EcoCash/OneMoney/TeleCash) for tenant apps |
| Merkle Audit | Rust | Batch hashing, inclusion proofs |

---

### GL-ARCH-010: Event Schema Evolution

| Attribute | Specification |
|-----------|---------------|
| **Statement** | Event schemas must be backward and forward compatible. No breaking changes to existing event types. |
| **Rationale** | Enables replay of historical events with new code versions. |
| **Enforcement** | • Protobuf schema versioning with `event_version` field.<br>• Schema registry validation in CI.<br>• Migration scripts for event transformations. |
| **Violation Effect** | Replay failures, state reconstruction errors, data loss. |

---

## 3. Compliance Alignment

### ISO 27001:2022
- **A.12.4**: Logging and Monitoring → Hash chain audit trails
- **A.8.11**: Data Integrity → Immutable ledger with triggers
- **A.9.4**: Access Control → RLS policies

### PCI DSS 4.0
- **Req 10**: Audit Trails → `audit.change_log`, `audit.session_log`
- **Req 11.5**: File Integrity → Hash chain verification
- **Req 3.4**: PAN Protection → `ussd.encrypt_msisdn()` function

### GDPR / Zimbabwe Data Protection Act
- **Art 17**: Right to Erasure → `core.anonymize_user_data()` function
- **Art 32**: Security → Encryption at rest, RLS, audit trails

---

## 4. Enforcement Checklist

Use this checklist in every PR:

```markdown
## Architecture Guardrails Checklist

- [ ] GL-ARCH-001: No cross-context calls outside `/protos/`
- [ ] GL-ARCH-002: Domain layer has zero infrastructure imports
- [ ] GL-ARCH-003: All writes via Go Orchestrator's AppendEvent
- [ ] GL-ARCH-004: CQRS separation maintained
- [ ] GL-ARCH-005: Session state from event replay only
- [ ] GL-ARCH-006: Hash chain fields populated
- [ ] GL-ARCH-007: RLS policies applied to new tables
- [ ] GL-ARCH-008: Idempotency keys validated
- [ ] GL-ARCH-009: Language boundaries respected
- [ ] GL-ARCH-010: Event schema backward compatible
```

---

## 5. References

- Immutable Ledger Migrations: `V001__extensions_and_schemas.sql` through `V073__security_hardening_rls.sql`
- Core Utilities: `V002__core_utilities.sql`
- Transaction Log: `V006__core_transaction_log.sql`
- Integrity Verification: `V067__integrity_verification.sql`
- USSD Session State: `V043__ussd_session_state.sql`
