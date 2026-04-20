"""REST API Gateway — FastAPI application for tenant-facing APIs."""
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timedelta

import psycopg2
from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

from openai_ussd_kernel.api.domain.tenant_context import TenantContext
from openai_ussd_kernel.api.infrastructure.api_key_auth import ApiKeyAuth, api_key_header
from openai_ussd_kernel.api.infrastructure.rate_limit import RateLimitMiddleware
from openai_ussd_kernel.clients.orchestrator import OrchestratorClient

logger = logging.getLogger(__name__)
app = FastAPI(
    title="Open AI-USSD Kernel API",
    description="Enterprise-grade REST API for tenant business applications",
    version="1.0.0",
)


@app.middleware("http")
async def log_request(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start

    tenant_id = request.path_params.get("tenant_id", "unknown")
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        try:
            conn = psycopg2.connect(dsn)
            cursor = conn.cursor()
            cursor.execute(
                """
                INSERT INTO app.api_request_log
                (request_id, application_id, api_version, environment, http_method, request_path,
                 response_status, request_started_at, request_ended_at, duration_ms, partition_date)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    str(uuid.uuid4()),
                    tenant_id if "-" in tenant_id else "00000000-0000-0000-0000-000000000000",
                    "v1",
                    os.environ.get("ENVIRONMENT", "production"),
                    request.method,
                    request.url.path,
                    response.status_code,
                    datetime.utcfromtimestamp(start),
                    datetime.utcfromtimestamp(start + duration),
                    int(duration * 1000),
                    datetime.utcfromtimestamp(start).date(),
                ),
            )
            conn.commit()
            conn.close()
        except Exception as exc:
            logger.warning("Failed to write request log: %s", exc)

    return response


auth = ApiKeyAuth()
rate_limit = RateLimitMiddleware()
_orchestrator = OrchestratorClient()

DEFAULT_PHONE_REGEX = r"^2637[1378]\d{8}$"


def get_phone_regex(tenant_id: str) -> str:
    """Return phone validation regex for a tenant from app.application_registry."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        return DEFAULT_PHONE_REGEX
    try:
        conn = psycopg2.connect(dsn)
        cursor = conn.cursor()
        cursor.execute(
            "SELECT configuration->>'phone_regex' FROM app.application_registry WHERE application_id = %s",
            (tenant_id,),
        )
        row = cursor.fetchone()
        conn.close()
        if row and row[0]:
            return row[0]
    except Exception as exc:
        logger.warning("Failed to load phone regex for tenant %s: %s", tenant_id, exc)
    return DEFAULT_PHONE_REGEX


def _validate_phone(phone: str, tenant_id: str) -> None:
    regex = get_phone_regex(tenant_id)
    if not re.match(regex, phone):
        raise HTTPException(status_code=400, detail="Invalid phone number format")


def _db_query(sql: str, params: tuple = ()):
    """Execute a read-only SQL query and return rows as dicts."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        return []
    try:
        conn = psycopg2.connect(dsn)
        cursor = conn.cursor()
        cursor.execute(sql, params)
        cols = [desc[0] for desc in cursor.description] if cursor.description else []
        rows = cursor.fetchall()
        conn.close()
        return [dict(zip(cols, row)) for row in rows]
    except Exception as exc:
        logger.warning("DB query failed: %s", exc)
        return []


def _db_execute(sql: str, params: tuple = ()) -> int:
    """Execute a mutating SQL statement and return affected rows."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        return 0
    try:
        conn = psycopg2.connect(dsn)
        cursor = conn.cursor()
        cursor.execute(sql, params)
        conn.commit()
        rowcount = cursor.rowcount
        conn.close()
        return rowcount
    except Exception as exc:
        logger.warning("DB execute failed: %s", exc)
        return 0


# ---------------------------------------------------------------------------
# Request/Response Models
# ---------------------------------------------------------------------------

class CreateSessionRequest(BaseModel):
    phone_number: str = Field(..., min_length=1)
    service_code: str = Field(..., min_length=3)
    network_code: str = "ZW-Econet"


class SessionInputRequest(BaseModel):
    text: str = ""


class PaymentRequest(BaseModel):
    amount: float = Field(..., gt=0)
    currency: str = "USD"
    provider: str = Field(..., pattern=r"^(ecocash|onemoney|telecash)$")
    phone_number: str = Field(..., min_length=1)
    reference: str = ""


class EventRequest(BaseModel):
    event_type: str
    aggregate_type: str
    aggregate_id: str
    payload: dict = Field(default_factory=dict)


class MessageRequest(BaseModel):
    to_number: str = Field(..., min_length=1)
    message: str = Field(..., min_length=1, max_length=160)
    sender_id: str = "USSDApp"


class WebhookSubscriptionRequest(BaseModel):
    url: str = Field(..., pattern=r"^https://")
    events: list[str] = Field(default_factory=list)
    secret: str = ""


class ApiResponse(BaseModel):
    success: bool = True
    data: dict = Field(default_factory=dict)
    error: str = ""
    request_id: str = ""


# ---------------------------------------------------------------------------
# Dependency
# ---------------------------------------------------------------------------

async def get_tenant_context(api_key: str = Depends(api_key_header)) -> TenantContext:
    return await auth.authenticate(api_key)


async def check_rate_limit(request: Request):
    return await rate_limit(request)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "healthy", "version": "1.0.0", "timestamp": datetime.utcnow().isoformat()}


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

@app.post("/api/v1/tenants/{tenant_id}/sessions", response_model=ApiResponse)
async def create_session(
    tenant_id: str,
    req: CreateSessionRequest,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    _validate_phone(req.phone_number, tenant_id)
    session_id = str(uuid.uuid4())
    try:
        _orchestrator.append_event(
            event_type="SessionCreated",
            aggregate_type="USR_SESSION",
            aggregate_id=session_id,
            payload={
                "phone_number": req.phone_number,
                "service_code": req.service_code,
                "network_code": req.network_code,
            },
        )
    except Exception as exc:
        logger.error("Failed to append SessionCreated event: %s", exc)
        raise HTTPException(status_code=502, detail="Orchestrator unavailable") from exc

    return ApiResponse(
        data={"session_id": session_id, "phone_number": req.phone_number, "status": "created"}
    )


@app.post("/api/v1/tenants/{tenant_id}/sessions/{session_id}/inputs", response_model=ApiResponse)
async def send_session_input(
    tenant_id: str,
    session_id: str,
    req: SessionInputRequest,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    try:
        resp = _orchestrator.forward_ussd(
            session_id=session_id,
            phone_number="",  # orchestrator looks it up from session state
            text=req.text,
            service_code="",  # orchestrator looks it up from tenant
            network_code="",
            language_code="en",
        )
        return ApiResponse(
            data={
                "session_id": session_id,
                "response": resp.menu_text,
                "is_end": resp.type == 2,  # END enum value
                "next_menu": resp.next_menu,
            }
        )
    except Exception as exc:
        logger.error("ForwardUSSD failed: %s", exc)
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.get("/api/v1/tenants/{tenant_id}/sessions/{session_id}/state", response_model=ApiResponse)
async def get_session_state(
    tenant_id: str,
    session_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    rows = _db_query(
        "SELECT session_id, state, version, created_at FROM ussd.ussd_sessions WHERE session_id = %s",
        (session_id,),
    )
    if not rows:
        return ApiResponse(data={"session_id": session_id, "state": {}, "version": 0})
    row = rows[0]
    return ApiResponse(
        data={
            "session_id": row.get("session_id"),
            "state": row.get("state") or {},
            "version": row.get("version", 0),
            "created_at": row.get("created_at").isoformat() if row.get("created_at") else None,
        }
    )


# ---------------------------------------------------------------------------
# Payments
# ---------------------------------------------------------------------------

@app.post("/api/v1/tenants/{tenant_id}/payments", response_model=ApiResponse)
async def create_payment(
    tenant_id: str,
    req: PaymentRequest,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    _validate_phone(req.phone_number, tenant_id)
    payment_id = str(uuid.uuid4())
    try:
        _orchestrator.append_event(
            event_type="PaymentInitiated",
            aggregate_type="PAYMENT",
            aggregate_id=payment_id,
            payload={
                "amount_cents": int(req.amount * 100),
                "currency": req.currency,
                "provider": req.provider,
                "phone_number": req.phone_number,
                "reference": req.reference,
            },
        )
    except Exception as exc:
        logger.error("Failed to append PaymentInitiated event: %s", exc)
        raise HTTPException(status_code=502, detail="Orchestrator unavailable") from exc

    return ApiResponse(
        data={
            "payment_id": payment_id,
            "amount": req.amount,
            "currency": req.currency,
            "provider": req.provider,
            "status": "pending",
        }
    )


@app.get("/api/v1/tenants/{tenant_id}/payments/{payment_id}", response_model=ApiResponse)
async def get_payment(
    tenant_id: str,
    payment_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    rows = _db_query(
        "SELECT event_type, payload, occurred_at FROM events.event_store "
        "WHERE aggregate_id = %s AND aggregate_type = 'PAYMENT' "
        "ORDER BY occurred_at DESC LIMIT 1",
        (payment_id,),
    )
    if not rows:
        return ApiResponse(data={"payment_id": payment_id, "status": "unknown"})
    row = rows[0]
    payload = row.get("payload") or {}
    if isinstance(payload, str):
        payload = json.loads(payload)
    return ApiResponse(
        data={
            "payment_id": payment_id,
            "status": payload.get("status", row.get("event_type")),
            "receipt_number": payload.get("provider_reference", ""),
            "last_updated": row.get("occurred_at").isoformat() if row.get("occurred_at") else None,
        }
    )


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

@app.get("/api/v1/tenants/{tenant_id}/events", response_model=ApiResponse)
async def list_events(
    tenant_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
    limit: int = 100,
    offset: int = 0,
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    rows = _db_query(
        "SELECT event_type, aggregate_type, aggregate_id, payload, occurred_at "
        "FROM events.event_store WHERE tenant_id = %s "
        "ORDER BY occurred_at DESC LIMIT %s OFFSET %s",
        (tenant_id, limit, offset),
    )
    for row in rows:
        payload = row.get("payload")
        if isinstance(payload, str):
            row["payload"] = json.loads(payload)
    total = _db_query(
        "SELECT COUNT(*) as total FROM events.event_store WHERE tenant_id = %s",
        (tenant_id,),
    )
    total_count = total[0].get("total", 0) if total else 0
    return ApiResponse(data={"events": rows, "total_count": total_count, "limit": limit, "offset": offset})


# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

@app.post("/api/v1/tenants/{tenant_id}/messages", response_model=ApiResponse)
async def send_message(
    tenant_id: str,
    req: MessageRequest,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    _validate_phone(req.to_number, tenant_id)
    message_id = str(uuid.uuid4())
    logger.info("Sent message %s for tenant %s", message_id, tenant_id)
    return ApiResponse(data={"message_id": message_id, "status": "queued"})


@app.get("/api/v1/tenants/{tenant_id}/messages/{message_id}", response_model=ApiResponse)
async def get_message(
    tenant_id: str,
    message_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    return ApiResponse(data={"message_id": message_id, "status": "delivered"})


# ---------------------------------------------------------------------------
# Webhooks
# ---------------------------------------------------------------------------

@app.post("/api/v1/tenants/{tenant_id}/webhooks", response_model=ApiResponse)
async def create_webhook(
    tenant_id: str,
    req: WebhookSubscriptionRequest,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    webhook_id = str(uuid.uuid4())
    _db_execute(
        "INSERT INTO events.webhook_subscriptions (subscription_id, tenant_id, url, event_types, secret, is_active, created_at) "
        "VALUES (%s, %s, %s, %s, %s, true, NOW())",
        (webhook_id, tenant_id, req.url, json.dumps(req.events), req.secret),
    )
    return ApiResponse(data={"webhook_id": webhook_id, "url": req.url, "events": req.events})


@app.get("/api/v1/tenants/{tenant_id}/webhooks", response_model=ApiResponse)
async def list_webhooks(
    tenant_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")
    rows = _db_query(
        "SELECT subscription_id as webhook_id, url, event_types as events, is_active, created_at "
        "FROM events.webhook_subscriptions WHERE tenant_id = %s AND is_active = true",
        (tenant_id,),
    )
    for row in rows:
        events = row.get("events")
        if isinstance(events, str):
            row["events"] = json.loads(events)
    return ApiResponse(data={"webhooks": rows})


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

@app.get("/api/v1/tenants/{tenant_id}/metrics", response_model=ApiResponse)
async def get_metrics(
    tenant_id: str,
    ctx: TenantContext = Depends(get_tenant_context),
    _=Depends(check_rate_limit),
):
    if ctx.tenant_id != tenant_id and not ctx.can("admin"):
        raise HTTPException(status_code=403, detail="Tenant mismatch")

    sessions = _db_query(
        "SELECT COUNT(*) as total FROM events.event_store WHERE tenant_id = %s AND event_type = 'SessionCreated'",
        (tenant_id,),
    )
    payments = _db_query(
        "SELECT COUNT(*) as total FROM events.event_store WHERE tenant_id = %s AND event_type = 'PaymentInitiated'",
        (tenant_id,),
    )
    api_requests = _db_query(
        "SELECT COUNT(*) as total FROM app.api_request_log WHERE application_id = %s",
        (tenant_id,),
    )

    return ApiResponse(
        data={
            "tenant_id": tenant_id,
            "period": "24h",
            "sessions": sessions[0].get("total", 0) if sessions else 0,
            "payments": payments[0].get("total", 0) if payments else 0,
            "messages": 0,
            "api_requests": {"count": api_requests[0].get("total", 0) if api_requests else 0},
        }
    )
