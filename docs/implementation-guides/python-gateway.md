# Python Gateway Implementation Guide

## Overview

The Python Gateway is the primary entry point for Africa's Talking (AT) USSD traffic, AI-driven personalization, tenant-facing REST APIs, and real-time analytics. It implements the **M3 Intelligence Layer** of the polyglot architecture.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Africa's Talking Cloud                    │
└─────────────────────┬───────────────────────────────────────┘
                      │ Webhook POST /gateway/webhook
                      ▼
┌─────────────────────────────────────────────────────────────┐
│  USSD Gateway (FastAPI)                                      │
│  ├─ Webhook handler (AT signature validation)                │
│  ├─ Session state manager (Redis)                            │
│  ├─ AI Brain client (gRPC → rust-engine)                    │
│  └─ Menu router                                              │
└─────────────────────┬───────────────────────────────────────┘
                      │ gRPC / REST
                      ▼
┌─────────────────────────────────────────────────────────────┐
│  REST API (FastAPI)                                          │
│  ├─ Tenant endpoints (API key auth → app.api_keys)          │
│  ├─ Transaction queries                                      │
│  ├─ Analytics dashboards                                     │
│  └─ Webhook management                                       │
└─────────────────────────────────────────────────────────────┘
```

## Africa's Talking Integration

### Webhook Handling

AT sends USSD requests via HTTP POST to `/gateway/webhook`. The payload contains:

| Field | Description |
|-------|-------------|
| `sessionId` | AT session identifier |
| `phoneNumber` | MSISDN (e.g., `263712345678`) |
| `networkCode` | MNO code (e.g., `26301` for Econet) |
| `serviceCode` | USSD short code |
| `text` | User input (accumulated, `*` delimited) |

### Signature Validation

Every AT webhook includes an `X-AT-Signature` header. The gateway validates it using HMAC-SHA256:

```python
validator = ATSignatureValidator(api_key=at_api_key)
if not validator.validate(request.body, signature_header):
    raise HTTPException(401, "Invalid signature")
```

**Configuration:** Set `AT_API_KEY` per tenant in `app.application_registry.configuration`.

### USSD Protocol Response Format

Responses must be plain text with a leading action indicator:

- `CON ` — Continue session (show next menu)
- `END ` — Terminate session (show final message)

Example:
```
CON Welcome to EcoCash
1. Send Money
2. Buy Airtime
3. Pay Bill
```

## Session State Management

Sessions are stored in Redis with TTL (default 5 minutes):

```
Key:    ussd:session:{session_id}
Value:  {"step": 3, "menu": "send_money", "amount": 500, "recipient": "263712345678"}
TTL:    300s
```

On session timeout, the gateway emits a `SessionExpired` event to the outbox.

## AI Brain Integration

The gateway calls the Rust AI Brain service via gRPC for:

| Feature | gRPC Method | Latency Target |
|---------|------------|----------------|
| Translation | `AIBrain.Translate` | < 200ms |
| Intent Detection | `AIBrain.DetectIntent` | < 150ms |
| Personalization | `AIBrain.Personalize` | < 100ms |
| PII Redaction | `AIBrain.RedactPII` | < 50ms |

Fallback: If gRPC is unavailable, use cached translations or static menu text.

## REST API Authentication

All REST endpoints require API key authentication via `X-API-Key` header.

### API Key Validation Flow

1. Extract `X-API-Key` header
2. SHA-256 hash the key
3. Query `app.api_keys` by `api_key_hash`
4. Verify `is_active = true` and `expires_at > NOW()`
5. Load `permissions` and `rate_limit_tier`
6. Set `app.current_tenant_id` on downstream DB connections

### Rate Limiting Tiers

| Tier | Requests/min | Burst |
|------|-------------|-------|
| `free` | 60 | 10 |
| `standard` | 600 | 100 |
| `premium` | 6000 | 500 |

## Redis Caching

| Cache Key Pattern | TTL | Purpose |
|------------------|-----|---------|
| `tenant:{id}:config` | 5min | Tenant settings |
| `menu:{lang}:{tenant}` | 1hr | Localized menus |
| `session:{id}` | 5min | Active USSD session |
| `rate_limit:{key}` | 1min | Rate limit counters |

## Error Handling

| Error Code | USSD Response | Log Level |
|-----------|--------------|-----------|
| `INVALID_PHONE` | END Invalid phone number. Please try again. | WARNING |
| `SESSION_TIMEOUT` | END Session expired. Dial *151# to restart. | INFO |
| `PAYMENT_FAILED` | END Payment could not be processed. | ERROR |
| `AI_UNAVAILABLE` | CON (static fallback menu) | WARNING |

## Monitoring

Prometheus metrics exposed on `:9090/metrics`:

- `ussd_webhook_requests_total` — Counter by status
- `ussd_webhook_duration_seconds` — Histogram
- `ussd_session_active` — Gauge
- `ussd_ai_calls_total` — Counter by method and status

## Security Checklist

- [x] AT signature validation on every webhook
- [x] API keys stored as SHA-256 hashes in PostgreSQL
- [x] Rate limiting per API key
- [x] Input sanitization before Redis storage
- [x] No raw SQL in handlers (parameterized queries only)
- [ ] mTLS on AI Brain gRPC (pending cert manager)
- [ ] PII detection on all outbound logs (pending ML model)
