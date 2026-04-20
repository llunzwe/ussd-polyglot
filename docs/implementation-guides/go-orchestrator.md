# Go Orchestrator Implementation Guide

**Version**: 1.0.0  
**Service**: go-orchestrator  
**Language**: Go 1.22+  
**Status**: Implementation Ready  

---

## 1. Overview

The Go Orchestrator is the **central nervous system** of the Open AI-USSD Kernel. It routes requests between services, manages tenant isolation, enforces rate limits, and is the **only service** that writes to the immutable ledger.

### Responsibilities

1. **Request Routing**: Forward USSD requests to correct tenant
2. **Event Writing**: Append events to PostgreSQL ledger
3. **Rate Limiting**: Enforce per-tenant and per-user limits
4. **Session Management**: Coordinate session lifecycle
5. **Tenant Registry**: Manage tenant registration and discovery

---

## 2. Project Structure

```
go-orchestrator/
├── cmd/
│   └── orchestrator/
│       └── main.go                 # Application entry point
├── internal/
│   ├── domain/                     # Pure business logic
│   │   ├── aggregate/
│   │   │   ├── session.go          # Session aggregate
│   │   │   └── tenant.go           # Tenant aggregate
│   │   ├── entity/
│   │   │   ├── event.go            # Event entity
│   │   │   └── routing.go          # Routing entity
│   │   ├── valueobject/
│   │   │   ├── money.go            # Money value object
│   │   │   └── phone.go            # Phone number VO
│   │   └── repository/
│   │       ├── event_repository.go # Event repository interface
│   │       └── tenant_repository.go # Tenant repository interface
│   │
│   ├── application/                # Use cases
│   │   ├── command/
│   │   │   ├── append_event.go     # Append event handler
│   │   │   ├── create_session.go   # Create session handler
│   │   │   └── register_tenant.go  # Register tenant handler
│   │   ├── query/
│   │   │   ├── get_session.go      # Get session query
│   │   │   └── list_tenants.go     # List tenants query
│   │   └── service/
│   │       ├── router.go           # Request router
│   │       └── rate_limiter.go     # Rate limiting service
│   │
│   ├── ports/                      # Interface definitions
│   │   ├── inbound/
│   │   │   ├── grpc_server.go      # gRPC server interface
│   │   │   └── http_handler.go     # HTTP handler interface
│   │   └── outbound/
│   │       ├── database.go         # Database port
│   │       ├── cache.go            # Cache port
│   │       ├── message_queue.go    # MQ port
│   │       └── tenant_client.go    # Tenant gRPC client
│   │
│   ├── adapters/                   # Implementations
│   │   ├── inbound/
│   │   │   ├── grpc/
│   │   │   │   ├── server.go       # gRPC server impl
│   │   │   │   └── interceptors.go # gRPC interceptors
│   │   │   └── http/
│   │   │       └── metrics.go      # HTTP metrics endpoint
│   │   └── outbound/
│   │       ├── postgres/
│   │       │   ├── event_store.go  # PostgreSQL event store
│   │       │   ├── tenant_repo.go  # PostgreSQL tenant repo
│   │       │   └── connection.go   # Connection pool
│   │       ├── redis/
│   │       │   ├── cache.go        # Redis cache impl
│   │       │   └── rate_limit.go   # Redis rate limiter
│   │       └── grpc/
│   │           ├── session_client.go # Session service client
│   │           └── tenant_client.go  # Tenant service client
│   │
│   └── infrastructure/             # Infrastructure concerns
│       ├── config/
│       │   └── config.go           # Configuration
│       ├── observability/
│       │   ├── tracing.go          # OpenTelemetry tracing
│       │   └── metrics.go          # Prometheus metrics
│       └── security/
│           ├── auth.go             # Authentication
│           └── tls.go              # TLS configuration
│
├── pkg/
│   └── api/                        # Public API types
│       └── generated/              # Generated protobuf code
│
├── proto/                          # Protobuf definitions
│   └── orchestrator.proto
│
├── deployments/
│   ├── docker/
│   │   └── Dockerfile
│   └── k8s/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── hpa.yaml
│
├── migrations/                     # Go-based migrations (if needed)
├── tests/
│   ├── unit/                       # Unit tests
│   ├── integration/                # Integration tests
│   └── e2e/                        # End-to-end tests
│
├── go.mod
├── go.sum
└── Makefile
```

---

## 3. Core Domain Implementation

### 3.1 Session Aggregate

```go
// internal/domain/aggregate/session.go
package aggregate

import (
    "time"
    "github.com/google/uuid"
)

// Session represents a USSD session aggregate
type Session struct {
    ID           uuid.UUID
    TenantID     uuid.UUID
    PhoneNumber  string
    CurrentMenu  string
    State        map[string]interface{}
    Version      int64
    CreatedAt    time.Time
    LastActivity time.Time
    ExpiresAt    time.Time
    Status       SessionStatus
    
    uncommittedEvents []Event
}

type SessionStatus int

const (
    SessionActive SessionStatus = iota
    SessionExpired
    SessionTerminated
)

// Event represents a domain event
type Event interface {
    EventType() string
    AggregateID() uuid.UUID
    OccurredAt() time.Time
}

// ApplyEvent applies an event to the session
func (s *Session) ApplyEvent(event Event) error {
    switch e := event.(type) {
    case *SessionCreatedEvent:
        s.applySessionCreated(e)
    case *MenuNavigatedEvent:
        s.applyMenuNavigated(e)
    case *InputReceivedEvent:
        s.applyInputReceived(e)
    case *SessionEndedEvent:
        s.applySessionEnded(e)
    default:
        return fmt.Errorf("unknown event type: %s", event.EventType())
    }
    
    s.Version++
    s.LastActivity = time.Now()
    return nil
}

func (s *Session) applySessionCreated(e *SessionCreatedEvent) {
    s.ID = e.SessionID
    s.TenantID = e.TenantID
    s.PhoneNumber = e.PhoneNumber
    s.CreatedAt = e.OccurredAt()
    s.Status = SessionActive
}

func (s *Session) applyMenuNavigated(e *MenuNavigatedEvent) {
    s.CurrentMenu = e.ToMenu
    s.State["previous_menu"] = e.FromMenu
}

// CreateSession creates a new session
func CreateSession(tenantID uuid.UUID, phoneNumber string) (*Session, error) {
    session := &Session{
        ID:        uuid.New(),
        TenantID:  tenantID,
        Status:    SessionActive,
        State:     make(map[string]interface{}),
        CreatedAt: time.Now(),
    }
    
    event := &SessionCreatedEvent{
        SessionID:   session.ID,
        TenantID:    tenantID,
        PhoneNumber: phoneNumber,
        occurredAt:  time.Now(),
    }
    
    if err := session.ApplyEvent(event); err != nil {
        return nil, err
    }
    
    session.uncommittedEvents = append(session.uncommittedEvents, event)
    return session, nil
}
```

### 3.2 Event Repository Interface

```go
// internal/domain/repository/event_repository.go
package repository

import (
    "context"
    "github.com/google/uuid"
    "openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
)

// EventRepository defines the event store interface
type EventRepository interface {
    // Append saves events to the event store
    Append(ctx context.Context, events []aggregate.Event) error
    
    // GetByAggregateID retrieves events for an aggregate
    GetByAggregateID(ctx context.Context, aggregateID uuid.UUID, fromVersion int64) ([]aggregate.Event, error)
    
    // GetBySessionID retrieves events for a session
    GetBySessionID(ctx context.Context, sessionID uuid.UUID, limit int) ([]aggregate.Event, error)
    
    // GetLatestVersion returns the latest version for an aggregate
    GetLatestVersion(ctx context.Context, aggregateID uuid.UUID) (int64, error)
    
    // CheckIdempotency checks if idempotency key exists
    CheckIdempotency(ctx context.Context, key string) (bool, error)
}
```

---

## 4. Application Layer

### 4.1 Append Event Handler

```go
// internal/application/command/append_event.go
package command

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    "github.com/google/uuid"
    "openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
    "openai-ussd-kernel/go-orchestrator/internal/domain/repository"
)

// AppendEventHandler handles event appending
type AppendEventHandler struct {
    eventRepo    repository.EventRepository
    idempotency  repository.IdempotencyChecker
    db           *sql.DB
}

func NewAppendEventHandler(
    eventRepo repository.EventRepository,
    idempotency repository.IdempotencyChecker,
    db *sql.DB,
) *AppendEventHandler {
    return &AppendEventHandler{
        eventRepo:   eventRepo,
        idempotency: idempotency,
        db:          db,
    }
}

// AppendEventCommand represents a command to append an event
type AppendEventCommand struct {
    EventType       string
    AggregateType   string
    AggregateID     uuid.UUID
    ExpectedVersion int64
    Payload         map[string]interface{}
    IdempotencyKey  string
    SessionContext  SessionContext
}

type SessionContext struct {
    SessionID   uuid.UUID
    PhoneNumber string
    TenantID    uuid.UUID
    CorrelationID string
    CausationID   string
}

// Handle executes the append event command
func (h *AppendEventHandler) Handle(ctx context.Context, cmd AppendEventCommand) (*AppendEventResult, error) {
    // Check idempotency
    if cmd.IdempotencyKey != "" {
        exists, err := h.idempotency.Check(ctx, cmd.IdempotencyKey)
        if err != nil {
            return nil, fmt.Errorf("idempotency check failed: %w", err)
        }
        if exists {
            return nil, ErrDuplicateEvent
        }
    }
    
    // Verify expected version for optimistic concurrency
    latestVersion, err := h.eventRepo.GetLatestVersion(ctx, cmd.AggregateID)
    if err != nil {
        return nil, fmt.Errorf("failed to get latest version: %w", err)
    }
    
    if latestVersion != cmd.ExpectedVersion {
        return nil, ErrConcurrencyConflict
    }
    
    // Create event
    event := &DomainEvent{
        ID:            uuid.New(),
        EventType:     cmd.EventType,
        AggregateType: cmd.AggregateType,
        AggregateID:   cmd.AggregateID,
        Version:       cmd.ExpectedVersion + 1,
        Payload:       cmd.Payload,
        SessionID:     cmd.SessionContext.SessionID,
        TenantID:      cmd.SessionContext.TenantID,
        CorrelationID: cmd.SessionContext.CorrelationID,
        CausationID:   cmd.SessionContext.CausationID,
        OccurredAt:    time.Now(),
    }
    
    // Begin transaction
    tx, err := h.db.BeginTx(ctx, &sql.TxOptions{
        Isolation: sql.LevelSerializable,
    })
    if err != nil {
        return nil, fmt.Errorf("failed to begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Append event
    if err := h.eventRepo.AppendTx(ctx, tx, []aggregate.Event{event}); err != nil {
        return nil, fmt.Errorf("failed to append event: %w", err)
    }
    
    // Store idempotency key
    if cmd.IdempotencyKey != "" {
        if err := h.idempotency.StoreTx(ctx, tx, cmd.IdempotencyKey, event.ID); err != nil {
            return nil, fmt.Errorf("failed to store idempotency key: %w", err)
        }
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return &AppendEventResult{
        EventID:     event.ID,
        Version:     event.Version,
        RecordedAt:  event.OccurredAt,
    }, nil
}

type AppendEventResult struct {
    EventID    uuid.UUID
    Version    int64
    RecordedAt time.Time
}

var (
    ErrDuplicateEvent       = fmt.Errorf("duplicate event: idempotency key already exists")
    ErrConcurrencyConflict  = fmt.Errorf("concurrency conflict: expected version mismatch")
)
```

### 4.2 Request Router

```go
// internal/application/service/router.go
package service

import (
    "context"
    "fmt"
    "time"
    
    "github.com/google/uuid"
    "google.golang.org/grpc"
    "openai-ussd-kernel/go-orchestrator/internal/domain/repository"
    pb "openai-ussd-kernel/go-orchestrator/pkg/api/generated"
)

// Router routes USSD requests to tenant applications
type Router struct {
    tenantRepo    repository.TenantRepository
    sessionClient SessionServiceClient
    rateLimiter   RateLimiter
    connections   map[string]*grpc.ClientConn
}

func NewRouter(
    tenantRepo repository.TenantRepository,
    sessionClient SessionServiceClient,
    rateLimiter RateLimiter,
) *Router {
    return &Router{
        tenantRepo:    tenantRepo,
        sessionClient: sessionClient,
        rateLimiter:   rateLimiter,
        connections:   make(map[string]*grpc.ClientConn),
    }
}

// RouteRequest routes a USSD request to the appropriate tenant
func (r *Router) RouteRequest(ctx context.Context, req *RouteRequest) (*RouteResponse, error) {
    // Rate limit check
    if !r.rateLimiter.Allow(ctx, req.PhoneNumber, 10) {
        return nil, ErrRateLimitExceeded
    }
    
    // Get tenant from service code
    tenant, err := r.tenantRepo.GetByServiceCode(ctx, req.ServiceCode)
    if err != nil {
        return nil, fmt.Errorf("tenant not found: %w", err)
    }
    
    if !tenant.Active {
        return nil, ErrTenantInactive
    }
    
    // Check tenant rate limit
    if !r.rateLimiter.AllowTenant(ctx, tenant.ID.String(), tenant.RateLimitRPS) {
        return nil, ErrTenantRateLimitExceeded
    }
    
    // Get or create session
    sessionState, err := r.getSessionState(ctx, req.SessionID, tenant.ID)
    if err != nil {
        return nil, fmt.Errorf("failed to get session: %w", err)
    }
    
    // Connect to tenant
    tenantClient, err := r.getTenantClient(ctx, tenant.Endpoint)
    if err != nil {
        return nil, fmt.Errorf("failed to connect to tenant: %w", err)
    }
    
    // Build gRPC request
    menuReq := &pb.MenuRequest{
        SessionId:    req.SessionID.String(),
        PhoneNumber:  req.PhoneNumber,
        UserInput:    req.UserInput,
        CurrentMenu:  sessionState.CurrentMenu,
        SessionState: convertToProtoStruct(sessionState.State),
        TenantId:     tenant.ID.String(),
        LanguageCode: req.LanguageCode,
        ServiceCode:  req.ServiceCode,
    }
    
    // Call tenant with timeout
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()
    
    menuResp, err := tenantClient.HandleMenu(ctx, menuReq)
    if err != nil {
        return nil, fmt.Errorf("tenant handler failed: %w", err)
    }
    
    // Update session if needed
    if menuResp.NextMenu != sessionState.CurrentMenu {
        if err := r.updateSessionMenu(ctx, req.SessionID, menuResp.NextMenu); err != nil {
            return nil, fmt.Errorf("failed to update session: %w", err)
        }
    }
    
    return &RouteResponse{
        Type:         menuResp.Type,
        Message:      menuResp.Message,
        Options:      convertOptions(menuResp.Options),
        EndSession:   menuResp.Type == pb.MenuResponse_END,
        UpdatedState: convertFromProtoStruct(menuResp.UpdatedState),
    }, nil
}

type RouteRequest struct {
    SessionID    uuid.UUID
    PhoneNumber  string
    UserInput    string
    ServiceCode  string
    LanguageCode string
}

type RouteResponse struct {
    Type         pb.MenuResponse_ResponseType
    Message      string
    Options      []MenuOption
    EndSession   bool
    UpdatedState map[string]interface{}
}
```

---

## 5. gRPC Server Implementation

```go
// internal/adapters/inbound/grpc/server.go
package grpc

import (
    "context"
    
    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
    
    "openai-ussd-kernel/go-orchestrator/internal/application/command"
    "openai-ussd-kernel/go-orchestrator/internal/application/service"
    pb "openai-ussd-kernel/go-orchestrator/pkg/api/generated"
)

// Server implements the gRPC orchestrator service
type Server struct {
    pb.UnimplementedOrchestratorServer
    
    appendEventHandler *command.AppendEventHandler
    router             *service.Router
}

func NewServer(
    appendEventHandler *command.AppendEventHandler,
    router *service.Router,
) *Server {
    return &Server{
        appendEventHandler: appendEventHandler,
        router:             router,
    }
}

// ForwardUSSD implements the ForwardUSSD RPC
func (s *Server) ForwardUSSD(ctx context.Context, req *pb.ForwardUSSDRequest) (*pb.ForwardUSSDResponse, error) {
    // Validate request
    if req.Session == nil {
        return nil, status.Error(codes.InvalidArgument, "session is required")
    }
    
    // Route request
    routeReq := &service.RouteRequest{
        SessionID:    parseUUID(req.Session.SessionId),
        PhoneNumber:  req.Session.PhoneNumber,
        UserInput:    req.UserInput,
        ServiceCode:  req.ServiceCode,
        LanguageCode: req.Session.LanguageCode,
    }
    
    routeResp, err := s.router.RouteRequest(ctx, routeReq)
    if err != nil {
        return nil, mapError(err)
    }
    
    return &pb.ForwardUSSDResponse{
        Type:         routeResp.Type,
        MenuText:     routeResp.Message,
        Options:      convertToProtoOptions(routeResp.Options),
        NextMenu:     routeResp.UpdatedState["current_menu"].(string),
        EndSession:   routeResp.EndSession,
        UpdatedState: convertToProtoStruct(routeResp.UpdatedState),
    }, nil
}

// AppendEvent implements the AppendEvent RPC
func (s *Server) AppendEvent(ctx context.Context, req *pb.AppendEventRequest) (*pb.AppendEventResponse, error) {
    cmd := command.AppendEventCommand{
        EventType:       req.EventType,
        AggregateType:   req.AggregateType,
        AggregateID:     parseUUID(req.AggregateId),
        ExpectedVersion: req.ExpectedVersion,
        Payload:         convertFromProtoStruct(req.Payload),
        IdempotencyKey:  req.IdempotencyKey,
        SessionContext: command.SessionContext{
            SessionID:     parseUUID(req.Context.SessionId),
            PhoneNumber:   req.Context.PhoneNumber,
            TenantID:      parseUUID(req.Context.TenantId),
            CorrelationID: req.CorrelationId,
            CausationID:   req.CausationId,
        },
    }
    
    result, err := s.appendEventHandler.Handle(ctx, cmd)
    if err != nil {
        return nil, mapError(err)
    }
    
    return &pb.AppendEventResponse{
        EventId:    result.EventID.String(),
        Version:    result.Version,
        RecordedAt: timestamppb.New(result.RecordedAt),
    }, nil
}

// Health implements the Health RPC
func (s *Server) Health(ctx context.Context, req *pb.HealthRequest) (*pb.HealthResponse, error) {
    return &pb.HealthResponse{
        Status:    pb.HealthResponse_SERVING,
        Version:   "1.0.0",
        Timestamp: timestamppb.Now(),
    }, nil
}

func mapError(err error) error {
    switch err {
    case command.ErrDuplicateEvent:
        return status.Error(codes.AlreadyExists, err.Error())
    case command.ErrConcurrencyConflict:
        return status.Error(codes.FailedPrecondition, err.Error())
    case service.ErrRateLimitExceeded:
        return status.Error(codes.ResourceExhausted, err.Error())
    default:
        return status.Error(codes.Internal, err.Error())
    }
}
```

---

## 6. PostgreSQL Adapter

```go
// internal/adapters/outbound/postgres/event_store.go
package postgres

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    
    "github.com/google/uuid"
    "openai-ussd-kernel/go-orchestrator/internal/domain/aggregate"
)

// EventStore implements the event repository using PostgreSQL
type EventStore struct {
    db *sql.DB
}

func NewEventStore(db *sql.DB) *EventStore {
    return &EventStore{db: db}
}

// AppendTx appends events within a transaction
func (s *EventStore) AppendTx(ctx context.Context, tx *sql.Tx, events []aggregate.Event) error {
    const query = `
        INSERT INTO events.event_store (
            event_id, event_type, aggregate_type, aggregate_id,
            version, payload, tenant_id, session_id,
            correlation_id, causation_id, occurred_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    `
    
    for _, event := range events {
        payload, err := json.Marshal(event.Payload())
        if err != nil {
            return fmt.Errorf("failed to marshal payload: %w", err)
        }
        
        _, err = tx.ExecContext(ctx, query,
            event.ID(),
            event.EventType(),
            event.AggregateType(),
            event.AggregateID(),
            event.Version(),
            payload,
            event.TenantID(),
            event.SessionID(),
            event.CorrelationID(),
            event.CausationID(),
            event.OccurredAt(),
        )
        if err != nil {
            return fmt.Errorf("failed to insert event: %w", err)
        }
    }
    
    return nil
}

// GetByAggregateID retrieves events for an aggregate
func (s *EventStore) GetByAggregateID(ctx context.Context, aggregateID uuid.UUID, fromVersion int64) ([]aggregate.Event, error) {
    const query = `
        SELECT event_id, event_type, aggregate_type, aggregate_id,
               version, payload, tenant_id, session_id,
               correlation_id, causation_id, occurred_at
        FROM events.event_store
        WHERE aggregate_id = $1 AND version >= $2
        ORDER BY version ASC
    `
    
    rows, err := s.db.QueryContext(ctx, query, aggregateID, fromVersion)
    if err != nil {
        return nil, fmt.Errorf("failed to query events: %w", err)
    }
    defer rows.Close()
    
    var events []aggregate.Event
    for rows.Next() {
        var event DomainEvent
        var payload []byte
        
        err := rows.Scan(
            &event.ID,
            &event.EventType,
            &event.AggregateType,
            &event.AggregateID,
            &event.Version,
            &payload,
            &event.TenantID,
            &event.SessionID,
            &event.CorrelationID,
            &event.CausationID,
            &event.OccurredAt,
        )
        if err != nil {
            return nil, fmt.Errorf("failed to scan event: %w", err)
        }
        
        if err := json.Unmarshal(payload, &event.Payload); err != nil {
            return nil, fmt.Errorf("failed to unmarshal payload: %w", err)
        }
        
        events = append(events, &event)
    }
    
    return events, rows.Err()
}
```

---

## 7. Configuration

```go
// internal/infrastructure/config/config.go
package config

import (
    "fmt"
    "os"
    "strconv"
    "time"
)

// Config holds all configuration
type Config struct {
    Server   ServerConfig
    Database DatabaseConfig
    Redis    RedisConfig
    Security SecurityConfig
}

type ServerConfig struct {
    GRPCPort     int
    HTTPPort     int
    ReadTimeout  time.Duration
    WriteTimeout time.Duration
}

type DatabaseConfig struct {
    Host            string
    Port            int
    User            string
    Password        string
    Database        string
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
}

type RedisConfig struct {
    Host     string
    Port     int
    Password string
    DB       int
}

type SecurityConfig struct {
    TLSEnabled bool
    CertFile   string
    KeyFile    string
}

// Load loads configuration from environment variables
func Load() (*Config, error) {
    return &Config{
        Server: ServerConfig{
            GRPCPort:     getEnvInt("GRPC_PORT", 9090),
            HTTPPort:     getEnvInt("HTTP_PORT", 8080),
            ReadTimeout:  getEnvDuration("READ_TIMEOUT", 30*time.Second),
            WriteTimeout: getEnvDuration("WRITE_TIMEOUT", 30*time.Second),
        },
        Database: DatabaseConfig{
            Host:            getEnv("DB_HOST", "localhost"),
            Port:            getEnvInt("DB_PORT", 5432),
            User:            getEnv("DB_USER", "ussd"),
            Password:        getEnv("DB_PASSWORD", ""),
            Database:        getEnv("DB_NAME", "ussd_kernel"),
            MaxOpenConns:    getEnvInt("DB_MAX_OPEN_CONNS", 25),
            MaxIdleConns:    getEnvInt("DB_MAX_IDLE_CONNS", 5),
            ConnMaxLifetime: getEnvDuration("DB_CONN_MAX_LIFETIME", 5*time.Minute),
        },
        Redis: RedisConfig{
            Host:     getEnv("REDIS_HOST", "localhost"),
            Port:     getEnvInt("REDIS_PORT", 6379),
            Password: getEnv("REDIS_PASSWORD", ""),
            DB:       getEnvInt("REDIS_DB", 0),
        },
        Security: SecurityConfig{
            TLSEnabled: getEnvBool("TLS_ENABLED", true),
            CertFile:   getEnv("TLS_CERT_FILE", "/etc/tls/cert.pem"),
            KeyFile:    getEnv("TLS_KEY_FILE", "/etc/tls/key.pem"),
        },
    }, nil
}

func getEnv(key, defaultValue string) string {
    if value := os.Getenv(key); value != "" {
        return value
    }
    return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
    if value := os.Getenv(key); value != "" {
        if i, err := strconv.Atoi(value); err == nil {
            return i
        }
    }
    return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
    if value := os.Getenv(key); value != "" {
        if b, err := strconv.ParseBool(value); err == nil {
            return b
        }
    }
    return defaultValue
}

func getEnvDuration(key string, defaultValue time.Duration) time.Duration {
    if value := os.Getenv(key); value != "" {
        if d, err := time.ParseDuration(value); err == nil {
            return d
        }
    }
    return defaultValue
}
```

---

## 8. Main Entry Point

```go
// cmd/orchestrator/main.go
package main

import (
    "context"
    "log"
    "net"
    "os"
    "os/signal"
    "syscall"
    
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials"
    
    "openai-ussd-kernel/go-orchestrator/internal/adapters/inbound/grpc"
    "openai-ussd-kernel/go-orchestrator/internal/adapters/outbound/postgres"
    "openai-ussd-kernel/go-orchestrator/internal/application/command"
    "openai-ussd-kernel/go-orchestrator/internal/infrastructure/config"
)

func main() {
    // Load configuration
    cfg, err := config.Load()
    if err != nil {
        log.Fatalf("Failed to load configuration: %v", err)
    }
    
    // Initialize database
    db, err := postgres.NewConnection(cfg.Database)
    if err != nil {
        log.Fatalf("Failed to connect to database: %v", err)
    }
    defer db.Close()
    
    // Initialize repositories
    eventRepo := postgres.NewEventStore(db)
    tenantRepo := postgres.NewTenantRepository(db)
    
    // Initialize handlers
    appendEventHandler := command.NewAppendEventHandler(eventRepo, db)
    
    // Initialize gRPC server
    grpcServer := grpc.NewServer(appendEventHandler, router)
    
    // Start server
    lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.Server.GRPCPort))
    if err != nil {
        log.Fatalf("Failed to listen: %v", err)
    }
    
    var opts []grpc.ServerOption
    if cfg.Security.TLSEnabled {
        creds, err := credentials.NewServerTLSFromFile(cfg.Security.CertFile, cfg.Security.KeyFile)
        if err != nil {
            log.Fatalf("Failed to load TLS credentials: %v", err)
        }
        opts = append(opts, grpc.Creds(creds))
    }
    
    server := grpc.NewServer(opts...)
    pb.RegisterOrchestratorServer(server, grpcServer)
    
    // Graceful shutdown
    go func() {
        sigChan := make(chan os.Signal, 1)
        signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
        <-sigChan
        
        log.Println("Shutting down gracefully...")
        server.GracefulStop()
    }()
    
    log.Printf("Starting gRPC server on port %d", cfg.Server.GRPCPort)
    if err := server.Serve(lis); err != nil {
        log.Fatalf("Failed to serve: %v", err)
    }
}
```

---

## 9. Testing

### 9.1 Unit Test Example

```go
// internal/application/command/append_event_test.go
package command

import (
    "context"
    "testing"
    
    "github.com/google/uuid"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
)

// Mock repositories
type MockEventRepository struct {
    mock.Mock
}

func (m *MockEventRepository) Append(ctx context.Context, events []aggregate.Event) error {
    args := m.Called(ctx, events)
    return args.Error(0)
}

func (m *MockEventRepository) GetLatestVersion(ctx context.Context, aggregateID uuid.UUID) (int64, error) {
    args := m.Called(ctx, aggregateID)
    return args.Get(0).(int64), args.Error(1)
}

func TestAppendEventHandler_Handle(t *testing.T) {
    // Setup
    mockEventRepo := new(MockEventRepository)
    handler := NewAppendEventHandler(mockEventRepo, nil)
    
    ctx := context.Background()
    aggregateID := uuid.New()
    
    mockEventRepo.On("GetLatestVersion", ctx, aggregateID).Return(int64(5), nil)
    mockEventRepo.On("Append", ctx, mock.Anything).Return(nil)
    
    cmd := AppendEventCommand{
        EventType:       "TestEvent",
        AggregateType:   "TestAggregate",
        AggregateID:     aggregateID,
        ExpectedVersion: 5,
        Payload:         map[string]interface{}{"key": "value"},
        IdempotencyKey:  "test-key-123",
    }
    
    // Execute
    result, err := handler.Handle(ctx, cmd)
    
    // Assert
    assert.NoError(t, err)
    assert.NotNil(t, result)
    assert.Equal(t, int64(6), result.Version)
    mockEventRepo.AssertExpectations(t)
}
```

### 9.2 Integration Test

```go
// tests/integration/orchestrator_test.go
package integration

import (
    "context"
    "testing"
    
    "github.com/stretchr/testify/suite"
    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/wait"
    
    pb "openai-ussd-kernel/go-orchestrator/pkg/api/generated"
)

type OrchestratorIntegrationTestSuite struct {
    suite.Suite
    postgresC testcontainers.Container
    client    pb.OrchestratorClient
}

func (s *OrchestratorIntegrationTestSuite) SetupSuite() {
    ctx := context.Background()
    
    // Start PostgreSQL container
    req := testcontainers.ContainerRequest{
        Image:        "timescale/timescaledb:latest-pg16",
        ExposedPorts: []string{"5432/tcp"},
        Env: map[string]string{
            "POSTGRES_USER":     "test",
            "POSTGRES_PASSWORD": "test",
            "POSTGRES_DB":       "test",
        },
        WaitingFor: wait.ForListeningPort("5432/tcp"),
    }
    
    postgresC, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
        ContainerRequest: req,
        Started:          true,
    })
    s.Require().NoError(err)
    s.postgresC = postgresC
    
    // Run migrations
    // ... migration code ...
    
    // Create gRPC client
    // ... client setup ...
}

func (s *OrchestratorIntegrationTestSuite) TearDownSuite() {
    ctx := context.Background()
    s.postgresC.Terminate(ctx)
}

func (s *OrchestratorIntegrationTestSuite) TestAppendEvent() {
    ctx := context.Background()
    
    req := &pb.AppendEventRequest{
        EventType:       "TestEvent",
        AggregateType:   "TestAggregate",
        AggregateId:     uuid.New().String(),
        ExpectedVersion: 0,
        IdempotencyKey:  "test-key",
    }
    
    resp, err := s.client.AppendEvent(ctx, req)
    
    s.NoError(err)
    s.NotNil(resp)
    s.Equal(int64(1), resp.Version)
}

func TestOrchestratorIntegration(t *testing.T) {
    suite.Run(t, new(OrchestratorIntegrationTestSuite))
}
```

---

## 10. Deployment

### 10.1 Dockerfile

```dockerfile
# Build stage
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Install dependencies
RUN apk add --no-cache git

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o orchestrator ./cmd/orchestrator

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Copy binary
COPY --from=builder /app/orchestrator .

# Expose ports
EXPOSE 9090 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run
CMD ["./orchestrator"]
```

### 10.2 Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-orchestrator
  labels:
    app: go-orchestrator
spec:
  replicas: 3
  selector:
    matchLabels:
      app: go-orchestrator
  template:
    metadata:
      labels:
        app: go-orchestrator
    spec:
      containers:
        - name: orchestrator
          image: ghcr.io/openai-ussd-kernel/go-orchestrator:latest
          ports:
            - containerPort: 9090
              name: grpc
            - containerPort: 8080
              name: http
          env:
            - name: GRPC_PORT
              value: "9090"
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: host
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: go-orchestrator
spec:
  selector:
    app: go-orchestrator
  ports:
    - port: 9090
      targetPort: 9090
      name: grpc
    - port: 8080
      targetPort: 8080
      name: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: go-orchestrator
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: go-orchestrator
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## 11. Makefile

```makefile
.PHONY: all build test clean proto docker

# Variables
BINARY_NAME=orchestrator
DOCKER_IMAGE=ghcr.io/openai-ussd-kernel/go-orchestrator
VERSION=$(shell git describe --tags --always --dirty)

# Default target
all: build

# Build the binary
build:
	go build -ldflags "-X main.version=$(VERSION)" -o bin/$(BINARY_NAME) ./cmd/orchestrator

# Run tests
test:
	go test -v -race -coverprofile=coverage.out ./...

# Run integration tests
test-integration:
	go test -v -tags=integration ./tests/integration/...

# Generate protobuf code
proto:
	protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		proto/*.proto

# Build Docker image
docker:
	docker build -t $(DOCKER_IMAGE):$(VERSION) .
	docker tag $(DOCKER_IMAGE):$(VERSION) $(DOCKER_IMAGE):latest

# Push Docker image
docker-push: docker
	docker push $(DOCKER_IMAGE):$(VERSION)
	docker push $(DOCKER_IMAGE):latest

# Run linter
lint:
	golangci-lint run

# Format code
fmt:
	go fmt ./...

# Clean build artifacts
clean:
	rm -rf bin/
	rm -f coverage.out

# Development run
dev:
	go run ./cmd/orchestrator

# Migration commands
migrate-up:
	migrate -path migrations -database "postgres://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=require" up

migrate-down:
	migrate -path migrations -database "postgres://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=require" down 1
```

---

## 12. Key Implementation Notes

### Performance Targets

| Metric | Target | Implementation |
|--------|--------|----------------|
| Event Append Latency | < 10ms | Connection pooling, prepared statements |
| Session Reconstruction | < 1ms | Redis caching, event replay optimization |
| Request Routing | < 50ms | gRPC keepalive, connection reuse |
| Throughput | 10,000 RPS | Goroutine pool, batch processing |

### Critical Paths

1. **USSD Request Flow**:
   ```
   Africa's Talking → Python Gateway → Go Orchestrator → Tenant App
                                          ↓
                                    PostgreSQL (event)
   ```

2. **Event Append Flow**:
   ```
   Service → Go Orchestrator → PostgreSQL (WAL)
                     ↓
               Hash Chain Trigger
                     ↓
               Audit Log Trigger
   ```

### Error Handling Strategy

| Error Type | Response | Retry |
|------------|----------|-------|
| IDEMPOTENCY_VIOLATION | Return existing event | No |
| CONCURRENCY_CONFLICT | Retry with new version | Yes (3x) |
| DB_CONNECTION_LOST | Circuit breaker | Yes (exponential) |
| RATE_LIMIT_EXCEEDED | 429 Too Many Requests | No |
| TENANT_NOT_FOUND | 404 Not Found | No |

---

**Status**: Implementation Ready  
**Next Steps**: 
1. Implement domain aggregates
2. Set up PostgreSQL connection
3. Write unit tests
4. Deploy to staging
