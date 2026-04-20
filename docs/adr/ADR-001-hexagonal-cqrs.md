# ADR-001: Adoption of DDD + Hexagonal Architecture + CQRS/ES

**Status**: Accepted  
**Date**: 2026-04-13  
**Deciders**: Architecture Review Board  

---

## Context

The Open AI-USSD Kernel requires a polyglot implementation (Python gateway/AI, Go orchestration, Rust engines) providing SDK and API endpoints for tenant applications, backed by a kernel-managed enterprise-grade immutable PostgreSQL ledger (V001-V073 migrations). We need an architecture that:

1. Supports multiple languages optimally
2. Leverages the immutable ledger as single source of truth
3. Enables low-latency USSD sessions (< 1s response)
4. Meets regulatory audit requirements
5. Scales to 100,000+ concurrent sessions

---

## Decision

We adopt **Domain-Driven Design + Hexagonal Architecture (Ports & Adapters) + CQRS + Event Sourcing** as the foundational architecture.

---

## Consequences

### Positive

- **Domain Purity**: Business logic isolated from infrastructure (database, HTTP, gRPC)
- **Testability**: Domain logic testable without mocks for external dependencies
- **Polyglot Freedom**: Each bounded context uses optimal language (Python/Go/Rust)
- **Scalability**: CQRS enables independent scaling of read/write paths
- **Auditability**: Event sourcing provides complete history
- **Regulatory Ready**: Immutable ledger with hash chaining enables tenant applications to meet PCI DSS/SOX requirements

### Negative

- **Learning Curve**: Team must learn DDD, CQRS, ES patterns
- **Complexity**: More moving parts than CRUD architecture
- ** eventual Consistency**: Read models may lag writes
- **Storage Growth**: Event store grows indefinitely

### Mitigations

- Comprehensive onboarding documentation
- Strong architectural guardrails (GL-ARCH-xxx)
- Materialized views for fast reads
- TimescaleDB compression for old events

---

## Alternatives Considered

### Option 1: Clean Architecture (Onion)

**Why Rejected**: Lacks explicit CQRS/ES guidance for our immutable ledger requirements.

### Option 2: Modular Monolith

**Why Rejected**: Insufficient polyglot isolation; prevents independent deployment of Rust engines.

### Option 3: Plain Microservices

**Why Rejected**: No domain purity enforcement; leads to "distributed ball of mud".

### Option 4: Blockchain Ledger

**Why Rejected**: Too slow for USSD requirements; overkill for single-tenant trust domain.

---

## Implementation

### Bounded Contexts

1. **USSD & Personalization** (Python)
2. **Orchestration & Routing** (Go)
3. **Session Management** (Rust)
4. **Payment Processing** (Rust)
5. **Audit & Integrity** (Rust)
6. **Core Ledger** (PostgreSQL - shared)

### Hexagonal Structure

```
service/
├── domain/          # Pure business logic
├── application/     # Use cases
├── ports/           # Interfaces
└── adapters/        # Implementations
```

### CQRS Separation

- **Command Side**: Go Orchestrator → AppendEvent → PostgreSQL
- **Query Side**: Materialized views, Redis cache, Rust replay

---

## References

- [Architecture Guardrails](../guardrails/architecture.md)
- [High-Level System Design](../system-design/high-level.md)
- [Immutable Ledger Migrations](../../V001__extensions_and_schemas.sql)

---

**Approved By**: [Architecture Review Board signatures]
