# 12-Month Product Roadmap

**Version**: 1.0.0  
**Status**: Draft for Review  
**Last Updated**: 2026-04-13  
**Horizon**: Q2 2026 - Q1 2027  

---

## 1. Executive Summary

This roadmap outlines the phased delivery of the Open AI-USSD Kernel Engine over 12 months, aligned with the immutable ledger architecture (V001-V073 migrations) and enterprise-grade standards.

### Strategic Objectives

1. **M1 (Q2 2026)**: Foundation - Immutable ledger + Rust engines
2. **M2 (Q3 2026)**: Orchestration - Go router + gRPC contracts
3. **M3 (Q4 2026)**: Intelligence - Python gateway + AI + SDK
4. **M4 (Q1 2027)**: Scale - Edge deployment + Merkle audit + Production

---

## 2. Roadmap Timeline (Gantt Chart)

```mermaid
gantt
    title Open AI-USSD Kernel Engine - 12 Month Roadmap
    dateFormat  YYYY-MM-DD
    section Phase 1: Foundation
    Ledger Setup & Migrations    :done, ledger, 2026-04-01, 2w
    Rust Session Reconstructor   :active, rs_sess, 2026-04-15, 6w
    Rust Payment Engine          :rs_pay, 2026-05-01, 8w
    Merkle Hashing Module        :merkle, 2026-05-15, 4w
    
    section Phase 2: Orchestration
    Protobuf Contracts           :proto, 2026-05-01, 4w
    Go Orchestrator Core         :go_core, 2026-06-01, 8w
    Tenant Routing System        :routing, 2026-06-15, 6w
    Rate Limiting & Throttling   :rate, 2026-07-01, 4w
    
    section Phase 3: Intelligence
    Python USSD Gateway          :py_gate, 2026-07-15, 6w
    AI Brain (SLM)               :ai, 2026-08-01, 8w
    Tenant SDK v1                :sdk, 2026-08-15, 8w
    Africa's Talking Integration :at, 2026-09-01, 4w
    
    section Phase 4: Scale
    Edge Raspberry Pi Nodes      :edge, 2026-10-01, 8w
    Merkle Audit Service         :audit_svc, 2026-10-15, 6w
    Regulatory Compliance Pack   :compliance, 2026-11-01, 8w
    Production Hardening         :prod, 2026-12-01, 10w
    
    section Milestones
    M1: Rust Engine Live         :milestone, m1, 2026-06-30, 0d
    M2: Orchestrator Live        :milestone, m2, 2026-08-31, 0d
    M3: SDK & AI Live            :milestone, m3, 2026-10-31, 0d
    M4: Production Ready         :milestone, m4, 2027-01-31, 0d
```

---

## 3. Quarterly Breakdown

### Q2 2026: Foundation (M1)

**Goal**: Immutable ledger operational with core Rust engines

| Deliverable | Owner | Status | Success Criteria |
|-------------|-------|--------|------------------|
| Ledger migrations V001-V073 | DBA | ✅ Complete | All migrations applied, tests passing |
| Rust Session Reconstructor | Rust Team | 🔄 In Progress | <1ms reconstruction latency |
| Rust Payment Engine | Rust Team | ⏳ Planned | EcoCash/OneMoney integration |
| Merkle Hashing | Rust Team | ⏳ Planned | Daily batch hashes computed |
| Integration tests | QA | ⏳ Planned | 100% hash chain verification |

**Key Activities:**
- Deploy PostgreSQL with TimescaleDB extension
- Implement Rust session reconstruction with event replay
- Build kernel-provided EcoCash/OneMoney API adapters for the tenant SDK
- Create hash chain verification functions
- Performance testing: 10,000 events/second

**Dependencies:**
- ✅ PostgreSQL 16+ with pgcrypto, uuid-ossp, timescaledb
- ✅ EcoCash sandbox API access
- 🔄 OneMoney API documentation

---

### Q3 2026: Orchestration (M2)

**Goal**: Go orchestrator routing traffic with gRPC contracts

| Deliverable | Owner | Status | Success Criteria |
|-------------|-------|--------|------------------|
| Protobuf contracts | Architecture | 🔄 In Progress | All service contracts defined |
| Go Orchestrator core | Go Team | ⏳ Planned | 10,000 concurrent sessions |
| Tenant routing | Go Team | ⏳ Planned | Dynamic tenant discovery |
| Rate limiting | Go Team | ⏳ Planned | Token bucket per tenant |
| Multi-tenant isolation | Security | ⏳ Planned | RLS policies enforced |

**Key Activities:**
- Define all gRPC protobuf contracts in `/protos/`
- Build Go orchestrator with goroutine pool
- Implement tenant registry with Kubernetes integration
- Build rate limiter with Redis backend
- Chaos testing: service failures, network partitions

**Dependencies:**
- M1 completion (Rust engines)
- Kubernetes cluster access
- Redis cluster deployment

---

### Q4 2026: Intelligence (M3)

**Goal**: Python gateway handling USSD with AI personalization

| Deliverable | Owner | Status | Success Criteria |
|-------------|-------|--------|------------------|
| Python USSD Gateway | Python Team | ⏳ Planned | Africa's Talking integration |
| AI Brain (SLM) | AI Team | ⏳ Planned | Shona/Ndebele translation |
| Tenant SDK v1 | Python Team | ⏳ Planned | 3 sample tenant apps |
| Payment flows end-to-end | Integration | ⏳ Planned | <3s payment completion |
| Developer documentation | Docs | ⏳ Planned | Complete SDK guide |

**Key Activities:**
- Build Flask/FastAPI USSD handler
- Deploy Small Language Model for translation
- Create Python SDK with decorators
- Build 3 sample tenant applications
- End-to-end testing with real mobile money via tenant applications

**Dependencies:**
- M2 completion (Orchestrator)
- Africa's Talking production account
- AI model training data

---

### Q1 2027: Scale (M4)

**Goal**: Production-ready with edge deployment and compliance

| Deliverable | Owner | Status | Success Criteria |
|-------------|-------|--------|------------------|
| Edge Raspberry Pi nodes | Edge Team | ⏳ Planned | Offline session reconstruction |
| Merkle Audit Service | Rust Team | ⏳ Planned | Regulatory-ready exports |
| PCI DSS compliance pack | Security | ⏳ Planned | Audit pass |
| Production hardening | DevOps | ⏳ Planned | 99.9% uptime SLA |
| Self-service onboarding | Product | ⏳ Planned | Zero-touch tenant signup |

**Key Activities:**
- Deploy Rust cache on Raspberry Pi with solar power
- Build Merkle proof generation service
- Complete PCI DSS SAQ validation
- Implement zero-downtime deployments
- Create tenant self-service portal

**Dependencies:**
- M3 completion
- Regulatory approval (RBZ, POTRAZ)
- Solar edge hardware

---

## 4. Milestone Details

### M1: Ledger + Rust Engine (June 30, 2026)

**Definition of Done:**
```yaml
ledger:
  migrations_applied: 73
  tables_created: 45
  triggers_active: 25
  rls_policies: 15
  
rust_session_reconstructor:
  latency_p99: "< 1ms"
  events_replay: 10000
  memory_usage: "< 100MB"
  
rust_payment_engine:
  providers:
    - ecocash
    - onemoney
  idempotency: 100%
  retry_success_rate: 99.5%
  
merkle_module:
  batch_computation: "daily"
  hash_verification: 100%
  proof_generation: "< 100ms"
```

**Exit Criteria:**
- [ ] All 73 database migrations applied successfully
- [ ] Session reconstruction < 1ms for 50 events
- [ ] Payment engine processes 1000 transactions/sec
- [ ] Hash chain verification passes 100%
- [ ] Security audit: no critical findings

---

### M2: Orchestrator + gRPC (August 31, 2026)

**Definition of Done:**
```yaml
grpc_contracts:
  proto_files: 8
  services_defined: 5
  backward_compatibility: enforced
  
go_orchestrator:
  concurrent_sessions: 10000
  latency_p99: "< 50ms"
  throughput: 5000_rps
  
tenant_routing:
  discovery: kubernetes
  isolation: rls_enforced
  rate_limits: per_tenant
  
rate_limiting:
  algorithm: token_bucket
  storage: redis
  burst_capacity: 100
```

**Exit Criteria:**
- [ ] All protobuf contracts in `/protos/`
- [ ] Go orchestrator handles 10K concurrent sessions
- [ ] Tenant isolation with RLS enforced
- [ ] Rate limiting: 10 req/sec per phone, 100 per tenant
- [ ] Load test: sustained 5000 RPS

---

### M3: Gateway + SDK (October 31, 2026)

**Definition of Done:**
```yaml
python_gateway:
  framework: fastapi
  ussd_handler: africa's_talking
  response_time: "< 100ms"
  
ai_brain:
  models:
    - translation_shona
    - translation_ndebele
    - personalization
  inference_latency: "< 200ms"
  
tenant_sdk:
  languages:
    - python
  decorators: ["@ussd.menu", "@session.persist"]
  sample_apps: 3
  
payment_flows:
  end_to_end_latency: "< 3s"
  success_rate: 99.9%
  reconciliation: automated
```

**Exit Criteria:**
- [ ] Python gateway handling USSD traffic
- [ ] AI translation for Shona/Ndebele
- [ ] SDK published to PyPI
- [ ] 3 sample tenant apps running
- [ ] End-to-end payment < 3 seconds

---

### M4: Production (January 31, 2027)

**Definition of Done:**
```yaml
edge_deployment:
  nodes: 50
  location: rural_zimbabwe
  power: solar
  sync: periodic
  
merkle_audit:
  proof_generation: automated
  export_format: ["json", "pdf"]
  regulatory_signature: enabled
  
compliance:
  pci_dss: saq_passed
  iso27001: certified
  gdpr: compliant
  
production:
  uptime_sla: 99.9%
  rto: 4_hours
  rpo: 15_minutes
  mttr: 30_minutes
```

**Exit Criteria:**
- [ ] 50 edge nodes deployed
- [ ] Regulatory compliance audit passed
- [ ] Production uptime: 99.9%
- [ ] Self-service tenant onboarding
- [ ] 24/7 operations runbook

---

## 5. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| **Telecash API unavailable** | High | Medium | Fallback to USSD automation (AT commands) |
| **Zimbabwe connectivity issues** | High | High | Edge deployment with offline capability |
| **Regulatory delays (RBZ)** | Medium | High | Early engagement, compliance-first design |
| **AI model performance** | Medium | Medium | Fallback to rule-based responses |
| **Talent acquisition** | Medium | High | Remote-friendly, training programs |
| **Solar power reliability** | Medium | Medium | Battery backup, low-power optimization |
| **Mobile money API changes** | Low | High | Adapter pattern, version negotiation |

---

## 6. Dependencies & External Factors

### External APIs
- ✅ Africa's Talking: Production account
- 🔄 EcoCash: Sandbox access, awaiting production
- ⏳ OneMoney: Documentation requested
- ⏳ Telecash: API access pending

### Regulatory
- 🔄 RBZ (Reserve Bank of Zimbabwe): Initial contact made
- ⏳ POTRAZ: License requirements being reviewed
- ⏳ Data Protection Authority: Compliance checklist

### Infrastructure
- ✅ Cloud: Kubernetes cluster provisioned
- ⏳ Edge: Solar hardware procurement in progress
- ⏳ Connectivity: VSAT backup for rural nodes

---

## 7. Success Metrics

### Technical Metrics

| Metric | M1 Target | M2 Target | M3 Target | M4 Target |
|--------|-----------|-----------|-----------|-----------|
| Session reconstruction | < 1ms | < 1ms | < 1ms | < 1ms |
| Payment processing | < 5s | < 3s | < 3s | < 2s |
| Concurrent sessions | 1,000 | 10,000 | 50,000 | 100,000 |
| System availability | 99% | 99.5% | 99.9% | 99.99% |
| Hash verification | 100% | 100% | 100% | 100% |

### Business Metrics

| Metric | M1 Target | M2 Target | M3 Target | M4 Target |
|--------|-----------|-----------|-----------|-----------|
| Tenant applications | 0 | 2 | 10 | 50 |
| Tenant daily transactions | 0 | 1,000 | 10,000 | 100,000 |
| Tenant active users | 0 | 500 | 5,000 | 50,000 |
| Tenant revenue facilitated (USD) | $0 | $0 | $5,000 | $50,000 |

---

## 8. Resource Requirements

### Team Structure

| Role | Q2 | Q3 | Q4 | Q1 |
|------|----|----|----|----|
| Rust Engineers | 2 | 2 | 1 | 1 |
| Go Engineers | 1 | 2 | 2 | 1 |
| Python Engineers | 1 | 2 | 3 | 2 |
| AI/ML Engineers | 0 | 1 | 2 | 2 |
| DevOps Engineers | 1 | 1 | 2 | 2 |
| QA Engineers | 1 | 1 | 2 | 2 |
| Security Engineer | 1 | 1 | 1 | 1 |
| Technical Writer | 0 | 1 | 1 | 1 |
| **Total** | **7** | **11** | **14** | **12** |

### Infrastructure Costs (Estimated)

| Component | M1 | M2 | M3 | M4 |
|-----------|----|----|----|----|
| Cloud (K8s) | $2,000 | $3,000 | $5,000 | $8,000 |
| PostgreSQL | $1,000 | $2,000 | $3,000 | $5,000 |
| Redis | $500 | $1,000 | $1,500 | $2,000 |
| Vault | $500 | $500 | $1,000 | $1,000 |
| Edge Nodes (50x) | $0 | $0 | $5,000 | $15,000 |
| Monitoring | $500 | $1,000 | $1,500 | $2,000 |
| **Total/Month** | **$4,500** | **$7,500** | **$17,000** | **$33,000** |

---

## 9. Review & Governance

### Monthly Review Cadence

1. **Week 1**: Sprint planning + technical review
2. **Week 2**: Progress check + blocker resolution
3. **Week 3**: Demo day + stakeholder feedback
4. **Week 4**: Retrospective + roadmap adjustment

### Milestone Gates

Each milestone requires sign-off from:
- Engineering Lead (technical completeness)
- Security Lead (compliance verification)
- Product Manager (feature acceptance)
- Operations Lead (deployment readiness)

### Roadmap Changes

Changes to this roadmap require:
1. Impact assessment on dependencies
2. Risk evaluation
3. Resource reallocation plan
4. Architecture Review Board approval
