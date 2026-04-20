# High-Level System Design

**Version**: 1.0.0  
**Status**: Approved  
**Last Updated**: 2026-04-13  

---

## 1. System Context Diagram (C4 Level 1)

> **Note**: The Open AI-USSD Kernel Engine is a kernel/SDK platform. It provides API endpoints and adapters (including mobile money) to **tenant applications**, which in turn serve end users. The kernel does not directly provide financial services to end users.

```mermaid
flowchart TB
    subgraph External["External Systems"]
        Farmer["👤 Rural Farmer<br/>(USSD Phone)"]
        AT["🌐 Africa's Talking<br/>(USSD Gateway)"]
        EcoCash["💳 EcoCash API"]
        OneMoney["💳 OneMoney API"]
        Telecash["💳 Telecash API"]
    end
    
    subgraph Kernel["Open AI-USSD Kernel"]
        PY["🐍 Python Gateway<br/>& AI Brain"]
        GO["🔵 Go Orchestrator<br/>& Router"]
        RS["🦀 Rust Engine<br/>(Session + Payment)"]
        DB["🗄️ PostgreSQL<br/>Immutable Ledger"]
    end
    
    subgraph Tenants["Tenant Applications"]
        T1["🏦 Microfinance App"]
        T2["🌾 Agritech App"]
        T3["🏥 Health Services"]
    end
    
    Farmer -->|"Dial *123#"| AT
    AT -->|"HTTP POST"| PY
    PY -->|"gRPC"| GO
    GO -->|"gRPC"| RS
    RS -->|"SQL"| DB
    GO -->|"gRPC"| T1
    GO -->|"gRPC"| T2
    GO -->|"gRPC"| T3
    RS -->|"HTTPS"| EcoCash
    RS -->|"HTTPS"| OneMoney
    RS -->|"HTTPS"| Telecash
    
    style Kernel fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style DB fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
```

---

## 2. Container Diagram (C4 Level 2)

```mermaid
flowchart TB
    subgraph "USSD Gateway & AI (Python)"
        Flask["Flask/FastAPI<br/>USSD Handler"]
        AI["AI Brain<br/>(SLM Inference)"]
        SDK["Tenant SDK<br/>(Python Library)"]
    end
    
    subgraph "Orchestrator (Go)"
        Router["Tenant Router"]
        EventWriter["Event Writer<br/>(AppendEvent)"]
        RateLimiter["Rate Limiter"]
        Registry["Tenant Registry"]
    end
    
    subgraph "Rust Engine"
        SessionRec["Session Reconstructor"]
        PaymentEng["Payment Engine"]
        Merkle["Merkle Hasher"]
    end
    
    subgraph "Immutable Ledger (PostgreSQL)"
        TxLog[("transaction_log<br/>Append-Only")]
        MoveLegs[("movement_legs<br/>Double-Entry")]
        EventStore[("event_store<br/>Event Sourcing")]
        Audit[("audit.change_log<br/>WORM")]
        Integrity[("integrity.batch_hashes<br/>Tamper-Proof")]
    end
    
    subgraph "Infrastructure"
        Redis[("Redis<br/>Session Cache")]
        Vault[("HashiCorp Vault<br/>Secrets")]
        OTel["OpenTelemetry<br/>Observability"]
    end
    
    Flask -->|"Forward USSD"| Router
    AI -->|"Personalize"| Flask
    SDK -->|"Build Apps"| Flask
    
    Router -->|"Route Request"| EventWriter
    Router -->|"Check Limit"| RateLimiter
    Router -->|"Lookup"| Registry
    
    EventWriter -->|"Write Event"| TxLog
    
    Router -->|"Get State"| SessionRec
    Router -->|"Initiate Payment"| PaymentEng
    
    SessionRec -->|"Replay Events"| EventStore
    PaymentEng -->|"Record Tx"| TxLog
    Merkle -->|"Batch Hash"| Integrity
    
    TxLog -->|"Hash Chain"| Audit
    MoveLegs -->|"Postings"| TxLog
    
    Router -->|"Cache"| Redis
    PaymentEng -->|"Fetch Secrets"| Vault
    
    Flask -.->|"Traces"| OTel
    Router -.->|"Traces"| OTel
    SessionRec -.->|"Traces"| OTel
    PaymentEng -.->|"Traces"| OTel
```

---

## 3. Component Flow: Complete USSD Payment

```mermaid
sequenceDiagram
    participant F as Farmer
    participant AT as Africa's Talking
    participant PY as Python Gateway
    participant GO as Go Orchestrator
    participant RS as Rust Session
    participant RP as Rust Payment
    participant DB as PostgreSQL
    participant MM as EcoCash
    participant T as Tenant App

    F->>AT: Dial *123*1# (USSD)
    AT->>PY: POST /ussd/callback
    PY->>GO: gRPC ForwardUSSD()
    GO->>RS: gRPC ReconstructSession()
    RS->>DB: SELECT events (replay)
    DB-->>RS: Event stream
    RS-->>GO: SessionState
    GO->>T: gRPC HandleMenu()
    T-->>GO: MenuResponse
    GO->>DB: INSERT event (ledger)
    GO-->>PY: USSD response
    PY-->>AT: CON Menu text
    AT-->>F: Display menu

    F->>AT: Select "Pay $10"
    AT->>PY: POST /ussd/callback
    PY->>GO: gRPC ForwardUSSD()
    GO->>RS: gRPC ReconstructSession()
    RS-->>GO: SessionState (with amount)
    GO->>RP: gRPC InitiatePayment()
    RP->>DB: INSERT PaymentInitiated
    RP->>MM: HTTPS POST /payment
    MM-->>RP: Ack (pending)
    RP-->>GO: PaymentPending
    GO->>T: gRPC HandleMenu()
    T-->>GO: Confirmation Menu
    GO-->>PY: USSD response
    PY-->>AT: CON "Processing..."
    AT-->>F: Display message

    MM->>GO: Webhook callback
    GO->>DB: INSERT PaymentConfirmed
    GO->>RS: gRPC ReconstructSession()
    GO->>T: gRPC HandleMenu()
    T-->>GO: Success Menu
    GO-->>PY: USSD response
    PY-->>AT: END "Payment complete!"
    AT-->>F: Display result
```

---

## 4. Data Flow Architecture

```mermaid
flowchart LR
    subgraph "Write Path (Command Side)"
        CMD[Command] -->|Validate| ORCH[Go Orchestrator]
        ORCH -->|Reserve ID| IDEMP[Idempotency Check]
        IDEMP -->|Compute Hash| HASH[Hash Chain]
        HASH -->|Insert| TX[(transaction_log)]
        TX -->|Trigger| AUDIT[(audit.change_log)]
        TX -->|Trigger| POST[(movement_postings)]
    end
    
    subgraph "Read Path (Query Side)"
        QUERY[Query] -->|Route| PROJ[Projection]
        PROJ -->|Materialized| VIEW[Materialized View]
        VIEW -->|Cache| REDIS[(Redis)]
        REDIS -->|Return| RESP[Response]
        
        QUERY -->|Replay| REPLAY[Event Replay]
        REPLAY -->|Fold| STATE[Session State]
        STATE -->|Return| RESP
    end
    
    TX -.->|Events| REPLAY
    
    style TX fill:#c8e6c9,stroke:#2e7d32
    style AUDIT fill:#fff3e0,stroke:#ef6c00
```

---

## 5. Event Sourcing Model

```mermaid
flowchart TB
    subgraph "Event Store (events.event_store)"
        E1["Event 1: SessionCreated<br/>stream_id, seq=1, payload"]
        E2["Event 2: MenuNavigated<br/>stream_id, seq=2, payload"]
        E3["Event 3: InputReceived<br/>stream_id, seq=3, payload"]
        E4["Event 4: PaymentInitiated<br/>stream_id, seq=4, payload"]
        E5["Event 5: PaymentConfirmed<br/>stream_id, seq=5, payload"]
    end
    
    subgraph "Session State (Fold)"
        S1["State 0: Empty"]
        S2["State 1: Created"]
        S3["State 2: At Menu"]
        S4["State 3: Awaiting Confirmation"]
        S5["State 4: Payment Pending"]
        S6["State 5: Complete"]
    end
    
    subgraph "Read Models (Projections)"
        P1["Active Sessions View"]
        P2["Payment Summary View"]
        P3["User Journey View"]
    end
    
    E1 -->|Apply| S2
    E2 -->|Apply| S3
    E3 -->|Apply| S4
    E4 -->|Apply| S5
    E5 -->|Apply| S6
    
    E1 -.->|Project| P1
    E4 -.->|Project| P2
    E1 -.->|Project| P3
    E5 -.->|Project| P3
    
    S6 -->|Query| API[API Response]
```

---

## 6. Hash Chain Integrity

```mermaid
flowchart LR
    subgraph "Blockchain-like Hash Chain"
        G["Genesis<br/>record_hash: 0x0000..."]
        T1["Tx 1<br/>previous_hash: 0x0000...<br/>record_hash: 0xabc1..."]
        T2["Tx 2<br/>previous_hash: 0xabc1...<br/>record_hash: 0xdef2..."]
        T3["Tx 3<br/>previous_hash: 0xdef2...<br/>record_hash: 0xghi3..."]
        B["Batch Hash<br/>hash of all tx hashes"]
    end
    
    G -->|links| T1
    T1 -->|links| T2
    T2 -->|links| T3
    
    T1 -.->|includes| B
    T2 -.->|includes| B
    T3 -.->|includes| B
    
    style G fill:#e8eaf6
    style B fill:#c8e6c9,stroke:#2e7d32
```

---

## 7. Multi-Tenancy Architecture

```mermaid
flowchart TB
    subgraph "Go Orchestrator"
        ROUTER["Tenant Router"]
    end
    
    subgraph "Tenant Isolation"
        RLS["Row-Level Security<br/>app.current_application_id"]
    end
    
    subgraph "PostgreSQL Ledger"
        direction TB
        TX_T1[("Tenant A<br/>transaction_log")]
        TX_T2[("Tenant B<br/>transaction_log")]
        TX_T3[("Tenant C<br/>transaction_log")]
    end
    
    subgraph "Tenant Applications"
        T1["🏦 Microfinance"]
        T2["🌾 Agriculture"]
        T3["🏥 Healthcare"]
    end
    
    T1 -->|"shortcode: *123*1#"| ROUTER
    T2 -->|"shortcode: *123*2#"| ROUTER
    T3 -->|"shortcode: *123*3#"| ROUTER
    
    ROUTER -->|"SET app.current_application_id"| RLS
    RLS -->|"Filter: app_id = 'A'"| TX_T1
    RLS -->|"Filter: app_id = 'B'"| TX_T2
    RLS -->|"Filter: app_id = 'C'"| TX_T3
    
    style RLS fill:#fff3e0,stroke:#ef6c00
```

---

## 8. Deployment Topology

```mermaid
flowchart TB
    subgraph "Cloud (Kubernetes)"
        subgraph "Control Plane"
            API[API Server]
            ETCD[etcd]
            SCHED[Scheduler]
        end
        
        subgraph "Worker Nodes"
            subgraph "Node 1"
                PY1[Python Gateway Pod]
                GO1[Go Orchestrator Pod]
            end
            
            subgraph "Node 2"
                RS1[Rust Engine Pod]
                RED[Redis Pod]
            end
            
            subgraph "Node 3"
                PG[(PostgreSQL Primary)]
                PG_S[(PostgreSQL Replica)]
            end
        end
        
        subgraph "Monitoring"
            PROM[Prometheus]
            GRAF[Grafana]
            JAEG[Jaeger]
        end
    end
    
    subgraph "Edge (Raspberry Pi)"
        EDGE_RUST[Rust Cache]
        EDGE_AI[Lightweight AI]
    end
    
    PY1 -->|gRPC| GO1
    GO1 -->|gRPC| RS1
    RS1 -->|SQL| PG
    GO1 -->|Cache| RED
    
    PG -->|Replication| PG_S
    
    PY1 -.->|Metrics| PROM
    GO1 -.->|Traces| JAEG
    PROM -->|Visualize| GRAF
    
    EDGE_RUST -.->|Sync| RS1
    
    style Cloud fill:#e3f2fd
    style Edge fill:#f3e5f5
```

---

## 9. Feedback Loops (Systems Thinking)

```mermaid
flowchart TB
    subgraph "Reinforcing Loops (Growth)"
        R1["R1: More Tenants → More Data → Better AI → More Tenants"]
        R2["R2: More Transactions → Lower Cost → Lower Fees → More Transactions"]
        R3["R3: Immutable Ledger → Trust → Regulatory Approval → More Enterprise Tenants"]
    end
    
    subgraph "Balancing Loops (Stability)"
        B1["B1: High Load → Throttling → Stable Latency"]
        B2["B2: Unreliable Connectivity → Edge Cache → Retained Users"]
        B3["B3: Fraud Attempts → Detection → Blocked → Reduced Fraud"]
    end
    
    subgraph "Leverage Points"
        L1["🔑 Immutable Ledger<br/>(Highest Leverage)"]
        L2["🔑 Tenant SDK<br/>(Ecosystem Growth)"]
    end
    
    R1 -->|Accelerates| L2
    R3 -->|Accelerates| L1
    B1 -->|Stabilizes| R1
    B2 -->|Enables| R1
```

---

## 10. Technology Stack

| Layer | Technology | Purpose |
|-------|------------|---------|
| **USSD Gateway** | Python 3.12, Flask/FastAPI | Africa's Talking integration |
| **AI Brain** | Python, PyTorch, Hugging Face | SLM inference, translation |
| **Orchestrator** | Go 1.22 | Routing, concurrency, event writing |
| **Engine** | Rust 1.77 | Session reconstruction, payments |
| **Ledger** | PostgreSQL 16, TimescaleDB | Immutable event store |
| **Cache** | Redis 7 | Session state, rate limiting |
| **Secrets** | HashiCorp Vault | API keys, credentials |
| **Observability** | OpenTelemetry, Grafana, Jaeger | Metrics, traces, logs |
| **Deployment** | Kubernetes, Helm | Container orchestration |
| **Edge** | Raspberry Pi, K3s | Offline capability |

---

## 11. Database Schema Overview

```mermaid
erDiagram
    transaction_log ||--o{ movement_legs : "contains"
    transaction_log ||--o{ movement_postings : "posts to"
    transaction_log ||--o{ audit_change_log : "audited by"
    ussd_sessions ||--o{ session_data : "stores"
    ussd_sessions ||--o{ session_history : "logs"
    event_store ||--o{ stream_sequences : "tracked by"
    account_registry ||--o{ transaction_log : "initiates"
    
    transaction_log {
        bigint transaction_id PK
        uuid transaction_uuid
        varchar idempotency_key
        uuid transaction_type_id
        uuid application_id
        uuid initiator_account_id
        jsonb payload
        numeric amount
        varchar status
        varchar record_hash
        varchar previous_hash
        timestamptz committed_at
    }
    
    movement_legs {
        uuid leg_id PK
        bigint transaction_id FK
        uuid account_id
        varchar direction
        numeric amount
        varchar currency
    }
    
    event_store {
        uuid event_id PK
        varchar event_type
        uuid stream_id
        bigint sequence_number
        jsonb payload
        timestamptz recorded_at
    }
    
    ussd_sessions {
        uuid session_id PK
        varchar session_code
        varchar msisdn
        bytea msisdn_encrypted
        uuid application_id
        varchar menu_state
        timestamptz started_at
        timestamptz expires_at
    }
```

---

## 12. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Architecture Pattern** | DDD + Hexagonal + CQRS/ES | Domain purity, testability, scalability |
| **Polyglot Stack** | Python/Go/Rust | Each language for its strength |
| **Communication** | gRPC + Protobuf | Performance, type safety |
| **Persistence** | PostgreSQL + TimescaleDB | ACID, time-series, proven technology |
| **Immutability** | Database Triggers | Enforced at DB level, tamper-proof |
| **Caching** | Redis | Speed, session management |
| **Secrets** | Vault CSI | Secure, rotatable, auditable |
| **Observability** | OpenTelemetry | Vendor-neutral, comprehensive |
| **Deployment** | Kubernetes | Scalable, self-healing |
| **Edge** | Raspberry Pi + Rust | Offline capability, low power |
