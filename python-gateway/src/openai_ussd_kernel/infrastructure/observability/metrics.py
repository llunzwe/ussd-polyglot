"""Prometheus metrics for the Python USSD Gateway."""

from prometheus_client import Counter, Histogram, make_asgi_app

ussd_requests_total = Counter(
    "ussd_requests_total",
    "Total USSD callback requests",
    ["service_code", "status"],
)

ussd_orchestrator_calls_total = Counter(
    "ussd_orchestrator_calls_total",
    "Total orchestrator gRPC calls",
    ["method", "status"],
)

ai_translations_total = Counter(
    "ai_translations_total",
    "Total AI translations",
    ["target_language"],
)

request_duration_seconds = Histogram(
    "gateway_request_duration_seconds",
    "HTTP request duration in seconds",
    ["path"],
)

__all__ = [
    "ussd_requests_total",
    "ussd_orchestrator_calls_total",
    "ai_translations_total",
    "request_duration_seconds",
    "make_asgi_app",
]
