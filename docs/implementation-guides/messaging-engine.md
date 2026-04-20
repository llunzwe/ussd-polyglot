# Messaging Engine Implementation Guide

## Overview

The Messaging Engine is a Rust hexagonal crate within the kernel that provides tenant applications with SMS, WhatsApp, and USSD push notification capabilities across Zimbabwean mobile network operators (MNOs). It exposes provider adapters (EcoCash/Econet, OneMoney/NetOne, TeleCash/Telecel) via the kernel's gRPC API and SDK.

## Provider Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Messaging Engine gRPC Server                                │
│  ├─ SendSMS                                                  │
│  ├─ SendWhatsApp                                             │
│  ├─ SendBulkSMS                                              │
│  ├─ GetDeliveryReceipt                                       │
│  └─ ... (9 total methods)                                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ EcoCash      │ │ OneMoney     │ │ TeleCash     │
│ Adapter      │ │ Adapter      │ │ Adapter      │
│ (REST/SMPP)  │ │ (SOAP)       │ │ (REST)       │
└──────────────┘ └──────────────┘ └──────────────┘
```

## Provider Routing by MSISDN

| Prefix Range | MNO | Provider | Adapter |
|-------------|-----|----------|---------|
| `26371`, `26377` | Econet | EcoCash | `EcoCashAdapter` |
| `26373` | Telecel | TeleCash | `TeleCashAdapter` |
| `26378` | NetOne | OneMoney | `OneMoneyAdapter` |

Routing is determined by the first 5 digits of the normalized MSISDN.

## EcoCash/Econet SMS API Integration

### Authentication

EcoCash uses API key + HMAC-SHA256 signature:

```rust
let signature = hmac_sha256(&api_secret, &payload_bytes);
let auth_header = format!("HMAC {}:{}", api_key, hex::encode(signature));
```

### Send SMS

```
POST https://api.ecocash.co.zw/v1/sms/send
Content-Type: application/json
Authorization: {auth_header}

{
  "to": "263712345678",
  "from": "EcoCash",
  "message": "Your verification code is 123456",
  "callback_url": "https://api.ussd.kernel/webhooks/ecocash/delivery"
}
```

### Delivery Receipt Handling

EcoCash POSTs delivery receipts to the configured callback URL:

```json
{
  "message_id": "msg-uuid",
  "status": "delivered",
  "delivered_at": "2026-04-17T10:30:00Z",
  "network_code": "26301"
}
```

Receipts are stored in `messaging.sms_delivery_receipts`.

## OneMoney/NetOne SOAP Integration

OneMoney uses a legacy SOAP API:

```xml
<soap:Envelope>
  <soap:Body>
    <SendSMS>
      <msisdn>263782345678</msisdn>
      <message>Your balance is ZWG 500.00</message>
      <shortCode>OneMoney</shortCode>
    </SendSMS>
  </soap:Body>
</soap:Envelope>
```

The `OneMoneyAdapter` uses `reqwest` with XML serialization via `quick-xml`.

## TeleCash/Telecel REST Integration

TeleCash provides a modern REST API with OAuth2:

```
POST /api/v2/messaging/sms
Authorization: Bearer {access_token}

{
  "recipient": "263732345678",
  "sender_id": "TeleCash",
  "body": "Transaction confirmation: ZWG 250.00 sent to 26371...",
  "delivery_report": true
}
```

## Template System

Templates are stored per schema and channel:

| Channel | Table | Columns |
|---------|-------|---------|
| SMS | `messaging.sms_templates` | `template_id`, `template_name`, `body`, `variables`, `tenant_id` |
| WhatsApp | `messaging.whatsapp_templates` | `template_id`, `template_name`, `body`, `variables`, `language`, `tenant_id` |

Variable substitution:
```rust
let body = template.body
    .replace("{{amount}}", &amount.to_string())
    .replace("{{currency}}", currency)
    .replace("{{recipient}}", recipient);
```

## Bulk Messaging

Bulk campaigns are managed through `messaging.sms_bulk_campaigns`:

```sql
INSERT INTO messaging.sms_bulk_campaigns
  (campaign_name, template_id, status, scheduled_at, tenant_id)
VALUES ('Monthly Statement', 'tpl-001', 'scheduled', NOW(), 'tenant-uuid');
```

Recipients are stored in `messaging.sms_bulk_recipients` with individual `status` tracking.

## Delivery Receipt Persistence

All delivery receipts are persisted for regulatory compliance:

```sql
INSERT INTO messaging.sms_delivery_receipts
  (message_id, provider_name, status, payload, received_at)
VALUES ($1, $2, $3, $4, NOW());
```

## Error Handling & Retry

| Provider Error | Action | Retry |
|----------------|--------|-------|
| `429 Too Many Requests` | Exponential backoff (1s, 2s, 4s) | Yes, max 3 |
| `500 Internal Server Error` | Circuit breaker OPEN | No, queue for later |
| `401 Unauthorized` | Refresh token / alert ops | No |
| Timeout | Retry with jitter | Yes, max 2 |

## Monitoring

Prometheus metrics:
- `messaging_sms_sent_total` — Counter by provider and status
- `messaging_sms_latency_seconds` — Histogram by provider
- `messaging_delivery_receipts_total` — Counter by status
- `messaging_bulk_queue_size` — Gauge

## Database Schema

Key tables (all in `messaging` schema):

```sql
messaging.sms_templates          -- Message templates
messaging.whatsapp_templates     -- WhatsApp-specific templates
messaging.sms_messages           -- Sent message log
messaging.sms_delivery_receipts  -- Provider delivery confirmations
messaging.sms_bulk_campaigns     -- Bulk campaign definitions
messaging.sms_bulk_recipients    -- Per-recipient campaign status
```
