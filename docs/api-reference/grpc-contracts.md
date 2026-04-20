# gRPC API Reference

**Version**: 1.0.0  
**Status**: Draft  
**Last Updated**: 2026-04-13  

---

## 1. Service Overview

| Service | Language | Port | Purpose |
|---------|----------|------|---------|
| `USSDGateway` | Python | 8080 | Africa's Talking integration |
| `Orchestrator` | Go | 9090 | Central routing & event writing |
| `SessionReconstructor` | Rust | 9091 | Event replay & state reconstruction |
| `PaymentEngine` | Rust | 9092 | Mobile money adapter service for tenant apps |
| `MerkleAudit` | Rust | 9093 | Hash verification & proofs |
| `TenantApplication` | Any | 9000 | Tenant USSD logic |

---

## 2. Protocol Definitions

### 2.1 Common Types

```protobuf
// common.proto
syntax = "proto3";
package ussd.common;

option go_package = "github.com/openai-ussd-kernel/protos/gen/go/common";

import "google/protobuf/timestamp.proto";

message UUID {
    string value = 1;
}

message Money {
    string currency_code = 1;  // ISO 4217 (e.g., "USD")
    int64 amount_cents = 2;     // Smallest currency unit
}

enum Status {
    STATUS_UNSPECIFIED = 0;
    STATUS_PENDING = 1;
    STATUS_PROCESSING = 2;
    STATUS_COMPLETED = 3;
    STATUS_FAILED = 4;
    STATUS_CANCELLED = 5;
}

message Error {
    string code = 1;
    string message = 2;
    map<string, string> details = 3;
}

message SessionContext {
    string session_id = 1;
    string phone_number = 2;
    string tenant_id = 3;
    map<string, string> metadata = 4;
    google.protobuf.Timestamp started_at = 5;
}
```

### 2.2 USSD Gateway Service

```protobuf
// ussd_gateway.proto
syntax = "proto3";
package ussd.gateway;

import "common.proto";

service USSDGateway {
    // Receive USSD request from Africa's Talking
    rpc ReceiveUSSD(USSDRequest) returns (USSDResponse);
    
    // Health check
    rpc Health(HealthRequest) returns (HealthResponse);
}

message USSDRequest {
    string session_id = 1;
    string phone_number = 2;
    string text = 3;              // User input (cumulative)
    string service_code = 4;      // USSD shortcode
    string network_code = 5;      // MNO identifier
    
    // Africa's Talking specific
    string at_session_id = 6;
    string at_network_code = 7;
}

message USSDResponse {
    enum ResponseType {
        CON = 0;  // Continue - keep session open
        END = 1;  // End - close session
    }
    
    ResponseType type = 1;
    string message = 2;           // Display text
    repeated string options = 3;  // Menu options (optional)
    
    // AI-enhanced fields
    bool ai_personalized = 4;
    string original_language = 5;
    string detected_language = 6;
}

message HealthRequest {}

message HealthResponse {
    bool healthy = 1;
    string version = 2;
    map<string, string> dependencies = 3;
}
```

### 2.3 Orchestrator Service

```protobuf
// orchestrator.proto
syntax = "proto3";
package ussd.orchestrator;

import "common.proto";
import "google/protobuf/struct.proto";

service Orchestrator {
    // Forward USSD request to tenant and get response
    rpc ForwardUSSD(ForwardUSSDRequest) returns (ForwardUSSDResponse);
    
    // Append event to immutable ledger
    rpc AppendEvent(AppendEventRequest) returns (AppendEventResponse);
    
    // Get session state (via SessionReconstructor)
    rpc GetSessionState(GetSessionStateRequest) returns (GetSessionStateResponse);
    
    // Register tenant application
    rpc RegisterTenant(RegisterTenantRequest) returns (RegisterTenantResponse);
    
    // Health check
    rpc Health(HealthRequest) returns (HealthResponse);
}

message ForwardUSSDRequest {
    ussd.common.SessionContext session = 1;
    string user_input = 2;
    string current_menu = 3;
    map<string, google.protobuf.Value> session_state = 4;
}

message ForwardUSSDResponse {
    string menu_text = 1;
    repeated MenuOption options = 2;
    string next_menu = 3;
    bool end_session = 4;
    map<string, google.protobuf.Value> updated_state = 5;
    
    message MenuOption {
        string id = 1;
        string label = 2;
        string action = 3;
    }
}

message AppendEventRequest {
    string event_type = 1;
    string aggregate_type = 2;
    string aggregate_id = 3;
    int64 expected_version = 4;
    google.protobuf.Struct payload = 5;
    string idempotency_key = 6;
    ussd.common.SessionContext context = 7;
}

message AppendEventResponse {
    string event_id = 1;
    int64 version = 2;
    google.protobuf.Timestamp recorded_at = 3;
    string record_hash = 4;
}

message GetSessionStateRequest {
    string session_id = 1;
    string tenant_id = 2;
    int32 max_events = 3;  // Default 50
}

message GetSessionStateResponse {
    string session_id = 1;
    map<string, google.protobuf.Value> state = 2;
    int64 version = 3;
    google.protobuf.Timestamp last_activity = 4;
}

message RegisterTenantRequest {
    string tenant_id = 1;
    string name = 2;
    string endpoint = 3;           // gRPC endpoint
    TenantType type = 4;
    int32 rate_limit_rps = 5;
    int64 monthly_quota = 6;
    
    enum TenantType {
        GRPC = 0;
        REST = 1;
    }
}

message RegisterTenantResponse {
    string tenant_id = 1;
    string api_key = 2;
    google.protobuf.Timestamp registered_at = 3;
}
```

### 2.4 Session Reconstructor Service

```protobuf
// session_reconstructor.proto
syntax = "proto3";
package ussd.session;

import "common.proto";
import "google/protobuf/struct.proto";

service SessionReconstructor {
    // Reconstruct session state from event stream
    rpc ReconstructSession(ReconstructSessionRequest) returns (ReconstructSessionResponse);
    
    // Get events for a session
    rpc GetSessionEvents(GetSessionEventsRequest) returns (GetSessionEventsResponse);
    
    // Verify session integrity
    rpc VerifySessionIntegrity(VerifySessionRequest) returns (VerifySessionResponse);
}

message ReconstructSessionRequest {
    string session_id = 1;
    string tenant_id = 2;
    int32 max_events = 3;          // Default 50, max 1000
    bool include_metadata = 4;
}

message ReconstructSessionResponse {
    string session_id = 1;
    map<string, google.protobuf.Value> state = 2;
    int64 current_version = 3;
    int32 events_replayed = 4;
    int64 replay_time_ms = 5;
    bool is_valid = 6;
    string integrity_hash = 7;
}

message GetSessionEventsRequest {
    string session_id = 1;
    string tenant_id = 2;
    int64 from_version = 3;        // Inclusive
    int64 to_version = 4;          // Inclusive, 0 = latest
}

message SessionEvent {
    string event_id = 1;
    string event_type = 2;
    int64 version = 3;
    google.protobuf.Struct payload = 4;
    google.protobuf.Timestamp occurred_at = 5;
    string causation_id = 6;
    string correlation_id = 7;
}

message GetSessionEventsResponse {
    string session_id = 1;
    repeated SessionEvent events = 2;
    int64 latest_version = 3;
}

message VerifySessionRequest {
    string session_id = 1;
    string expected_hash = 2;
}

message VerifySessionResponse {
    bool is_valid = 1;
    string computed_hash = 2;
    string expected_hash = 3;
    int64 event_count = 4;
}
```

### 2.5 Payment Engine Service

```protobuf
// payment_engine.proto
syntax = "proto3";
package ussd.payment;

import "common.proto";

service PaymentEngine {
    // Initiate mobile money payment on behalf of a tenant application
    rpc InitiatePayment(InitiatePaymentRequest) returns (InitiatePaymentResponse);
    
    // Check payment status
    rpc GetPaymentStatus(GetPaymentStatusRequest) returns (GetPaymentStatusResponse);
    
    // Refund a payment
    rpc RefundPayment(RefundPaymentRequest) returns (RefundPaymentResponse);
    
    // Callback from mobile money provider to tenant app via kernel
    rpc ProviderCallback(ProviderCallbackRequest) returns (ProviderCallbackResponse);
}

message InitiatePaymentRequest {
    string payment_id = 1;
    string tenant_id = 2;
    string session_id = 3;
    
    MobileMoneyProvider provider = 4;
    string phone_number = 5;
    ussd.common.Money amount = 6;
    string reference = 7;
    string description = 8;
    
    // Idempotency
    string idempotency_key = 9;
    
    // Callback URL for async notifications
    string callback_url = 10;
    
    enum MobileMoneyProvider {
        ECOCASH = 0;
        ONEMONEY = 1;
        TELECASH = 2;
    }
}

message InitiatePaymentResponse {
    string payment_id = 1;
    PaymentStatus status = 2;
    string provider_reference = 3;
    google.protobuf.Timestamp initiated_at = 4;
    int32 estimated_completion_seconds = 5;
    
    enum PaymentStatus {
        PENDING = 0;
        PROCESSING = 1;
        REQUIRES_CONFIRMATION = 2;
        COMPLETED = 3;
        FAILED = 4;
        CANCELLED = 5;
    }
}

message GetPaymentStatusRequest {
    string payment_id = 1;
}

message GetPaymentStatusResponse {
    string payment_id = 1;
    PaymentStatus status = 2;
    ussd.common.Money amount = 3;
    string provider_reference = 4;
    google.protobuf.Timestamp initiated_at = 5;
    google.protobuf.Timestamp completed_at = 6;
    string failure_reason = 7;
}

message RefundPaymentRequest {
    string original_payment_id = 1;
    string refund_id = 2;
    ussd.common.Money amount = 3;  // Partial refund supported
    string reason = 4;
    string idempotency_key = 5;
}

message RefundPaymentResponse {
    string refund_id = 1;
    RefundStatus status = 2;
    ussd.common.Money amount = 3;
    
    enum RefundStatus {
        PENDING = 0;
        PROCESSING = 1;
        COMPLETED = 2;
        FAILED = 3;
    }
}

message ProviderCallbackRequest {
    MobileMoneyProvider provider = 1;
    string provider_reference = 2;
    string payment_id = 3;
    CallbackStatus status = 4;
    ussd.common.Money amount = 5;
    string signature = 6;  // HMAC verification
    map<string, string> metadata = 7;
    
    enum CallbackStatus {
        SUCCESS = 0;
        FAILED = 1;
        TIMEOUT = 2;
        CANCELLED = 3;
    }
}

message ProviderCallbackResponse {
    bool accepted = 1;
    string message = 2;
}
```

### 2.6 Merkle Audit Service

```protobuf
// merkle_audit.proto
syntax = "proto3";
package ussd.audit;

import "common.proto";

service MerkleAudit {
    // Compute batch hash for a time period
    rpc ComputeBatchHash(ComputeBatchHashRequest) returns (ComputeBatchHashResponse);
    
    // Verify batch hash integrity
    rpc VerifyBatchHash(VerifyBatchHashRequest) returns (VerifyBatchHashResponse);
    
    // Generate inclusion proof for a transaction
    rpc GenerateInclusionProof(GenerateInclusionProofRequest) returns (GenerateInclusionProofResponse);
    
    // Verify inclusion proof
    rpc VerifyInclusionProof(VerifyInclusionProofRequest) returns (VerifyInclusionProofResponse);
    
    // Export signed audit report
    rpc ExportAuditReport(ExportAuditReportRequest) returns (ExportAuditReportResponse);
}

message ComputeBatchHashRequest {
    string date = 1;  // YYYY-MM-DD
    string period_type = 2;  // hourly, daily, weekly, monthly
}

message ComputeBatchHashResponse {
    string batch_id = 1;
    string batch_hash = 2;
    string previous_batch_hash = 3;
    int64 record_count = 4;
    google.protobuf.Timestamp computed_at = 5;
}

message VerifyBatchHashRequest {
    string batch_id = 1;
    string expected_hash = 2;
}

message VerifyBatchHashResponse {
    bool is_valid = 1;
    string computed_hash = 2;
    int64 transactions_verified = 3;
}

message GenerateInclusionProofRequest {
    string transaction_id = 1;
    string batch_id = 2;
}

message InclusionProof {
    string transaction_id = 1;
    string transaction_hash = 2;
    repeated string sibling_hashes = 3;
    int32 leaf_index = 4;
    string root_hash = 5;
}

message GenerateInclusionProofResponse {
    InclusionProof proof = 1;
    bool found = 2;
}

message VerifyInclusionProofRequest {
    InclusionProof proof = 1;
}

message VerifyInclusionProofResponse {
    bool is_valid = 1;
    string computed_root = 2;
    string expected_root = 3;
}

message ExportAuditReportRequest {
    string tenant_id = 1;
    string date_from = 2;
    string date_to = 3;
    ExportFormat format = 4;
    
    enum ExportFormat {
        JSON = 0;
        PDF = 1;
        CSV = 2;
    }
}

message ExportAuditReportResponse {
    string report_id = 1;
    string download_url = 2;
    string checksum = 3;
    bytes signature = 4;
    google.protobuf.Timestamp expires_at = 5;
}
```

### 2.7 Tenant Application Service

```protobuf
// tenant_application.proto
syntax = "proto3";
package ussd.tenant;

import "common.proto";
import "google/protobuf/struct.proto";

// This service is implemented by tenant applications
service TenantUSSDApp {
    // Handle USSD menu request
    rpc HandleMenu(MenuRequest) returns (MenuResponse);
    
    // Health check for tenant
    rpc Health(HealthRequest) returns (HealthResponse);
}

message MenuRequest {
    string session_id = 1;
    string phone_number = 2;
    string user_input = 3;
    string current_menu = 4;
    map<string, google.protobuf.Value> session_state = 5;
    string tenant_id = 6;
    string language_code = 7;
}

message MenuResponse {
    enum ResponseType {
        CON = 0;  // Continue session
        END = 1;  // End session
    }
    
    ResponseType type = 1;
    string message = 2;
    repeated MenuOption options = 3;
    string next_menu = 4;
    map<string, google.protobuf.Value> updated_state = 5;
    
    // AI integration
    bool use_ai_personalization = 6;
    string ai_prompt = 7;
    
    // Payment integration
    PaymentRequest payment = 8;
    
    message MenuOption {
        string id = 1;
        string label = 2;
        string next_menu = 3;
        string action = 4;
    }
    
    message PaymentRequest {
        string provider = 1;  // ecocash, onemoney, telecash
        ussd.common.Money amount = 2;
        string reference = 3;
        string description = 4;
    }
}

message HealthRequest {}

message HealthResponse {
    bool healthy = 1;
    string version = 2;
    map<string, string> metadata = 3;
}
```

---

## 3. Error Codes

| Code | HTTP Equivalent | Description |
|------|-----------------|-------------|
| `OK` | 200 | Success |
| `CANCELLED` | 499 | Request cancelled by client |
| `UNKNOWN` | 500 | Unknown error |
| `INVALID_ARGUMENT` | 400 | Invalid request parameter |
| `DEADLINE_EXCEEDED` | 504 | Request timeout |
| `NOT_FOUND` | 404 | Resource not found |
| `ALREADY_EXISTS` | 409 | Resource already exists |
| `PERMISSION_DENIED` | 403 | Insufficient permissions |
| `RESOURCE_EXHAUSTED` | 429 | Rate limit exceeded |
| `FAILED_PRECONDITION` | 412 | Precondition not met |
| `ABORTED` | 409 | Operation aborted |
| `OUT_OF_RANGE` | 400 | Value out of range |
| `UNIMPLEMENTED` | 501 | Method not implemented |
| `INTERNAL` | 500 | Internal server error |
| `UNAVAILABLE` | 503 | Service unavailable |
| `DATA_LOSS` | 500 | Data integrity error |
| `UNAUTHENTICATED` | 401 | Authentication required |

**Custom Application Codes:**

| Code | Description |
|------|-------------|
| `IDEMPOTENCY_VIOLATION` | Duplicate idempotency key |
| `DOUBLE_ENTRY_IMBALANCE` | Accounting imbalance detected |
| `CURRENCY_MISMATCH` | Leg currency mismatch |
| `FOREIGN_KEY_VIOLATION` | Referential integrity error |
| `HASH_CHAIN_BROKEN` | Tampering detected |
| `SESSION_TIMEOUT` | USSD session expired |
| `PAYMENT_PROVIDER_ERROR` | Mobile money API error |
| `TENANT_NOT_FOUND` | Unknown tenant ID |
| `RATE_LIMIT_EXCEEDED` | Too many requests |

---

## 4. Code Generation

### Go

```bash
# Generate Go code
protoc \
    --go_out=./gen/go \
    --go-grpc_out=./gen/go \
    --go_opt=paths=source_relative \
    --go-grpc_opt=paths=source_relative \
    protos/**/*.proto
```

### Python

```bash
# Generate Python code
python -m grpc_tools.protoc \
    -I./protos \
    --python_out=./gen/python \
    --grpc_python_out=./gen/python \
    protos/**/*.proto
```

### Rust

```bash
# Generate Rust code (using tonic-build)
cargo build --features generate-protos
```

---

## 5. Usage Examples

### Python Client

```python
import grpc
from protos import orchestrator_pb2, orchestrator_pb2_grpc

def forward_ussd():
    channel = grpc.insecure_channel('localhost:9090')
    stub = orchestrator_pb2_grpc.OrchestratorStub(channel)
    
    request = orchestrator_pb2.ForwardUSSDRequest(
        session=orchestrator_pb2.SessionContext(
            session_id='sess-123',
            phone_number='+263712345678',
            tenant_id='microfinance-zim'
        ),
        user_input='1',
        current_menu='main'
    )
    
    response = stub.ForwardUSSD(request)
    print(f"Menu: {response.menu_text}")
```

### Go Client

```go
package main

import (
    "context"
    "log"
    "google.golang.org/grpc"
    pb "github.com/openai-ussd-kernel/protos/gen/go/orchestrator"
)

func main() {
    conn, err := grpc.Dial("localhost:9090", grpc.WithInsecure())
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()
    
    client := pb.NewOrchestratorClient(conn)
    
    resp, err := client.AppendEvent(context.Background(), &pb.AppendEventRequest{
        EventType:      "PaymentInitiated",
        AggregateType:  "Payment",
        AggregateId:    "pay-123",
        IdempotencyKey: "idem-123",
    })
    
    if err != nil {
        log.Fatal(err)
    }
    
    log.Printf("Event recorded: %s", resp.EventId)
}
```

### Rust Client

```rust
use tonic::Request;
use payment::payment_engine_client::PaymentEngineClient;
use payment::InitiatePaymentRequest;

pub mod payment {
    tonic::include_proto!("ussd.payment");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = PaymentEngineClient::connect("http://localhost:9092").await?;
    
    let request = Request::new(InitiatePaymentRequest {
        payment_id: "pay-123".to_string(),
        tenant_id: "tenant-1".to_string(),
        provider: 0, // ECOCASH
        phone_number: "263712345678".to_string(),
        amount: Some(ussd::common::Money {
            currency_code: "USD".to_string(),
            amount_cents: 1000,
        }),
        reference: "REF-123".to_string(),
        ..Default::default()
    });
    
    let response = client.initiate_payment(request).await?;
    println!("Payment status: {:?}", response);
    
    Ok(())
}
```
