"""FastAPI gateway application for Africa's Talking USSD callbacks."""

import logging
import time

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
from prometheus_client import make_asgi_app

from openai_ussd_kernel.gateway.config import settings
from openai_ussd_kernel.gateway.handlers import ussd_callback
from openai_ussd_kernel.gateway.models import UssdRequest
from openai_ussd_kernel.infrastructure.observability import (
    get_trace_id,
    request_duration_seconds,
    set_trace_id,
)


class JsonFormatter(logging.Formatter):
    """Stub JSON formatter for structured logging."""

    def format(self, record):
        import json

        return json.dumps(
            {
                "timestamp": self.formatTime(record),
                "level": record.levelname,
                "service": "python-gateway",
                "message": record.getMessage(),
                "attributes": getattr(record, "attributes", {}),
            }
        )


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("python-gateway")

app = FastAPI(
    title="Open AI-USSD Kernel Engine - Python Gateway",
    description="Receives USSD callbacks from Africa's Talking and routes them to the Go Orchestrator.",
    version="1.0.0",
)

# Mount Prometheus metrics at /metrics
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    start = time.time()
    trace_id = request.headers.get("x-trace-id", "") or get_trace_id()
    set_trace_id(trace_id)

    response = await call_next(request)

    duration = time.time() - start
    request_duration_seconds.labels(path=request.url.path).observe(duration)
    logger.info(
        "request completed",
        extra={
            "attributes": {
                "path": request.url.path,
                "duration_seconds": duration,
                "trace_id": trace_id,
                "status_code": response.status_code,
            }
        },
    )
    return response


@app.get("/health")
async def health() -> dict:
    """Basic health check endpoint."""
    return {"status": "ok", "service": "python-gateway"}


@app.post("/ussd/callback", response_class=PlainTextResponse)
async def ussd_callback_endpoint(request: UssdRequest) -> str:
    """Africa's Talking USSD callback handler."""
    return ussd_callback(request)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=settings.gateway_port)
