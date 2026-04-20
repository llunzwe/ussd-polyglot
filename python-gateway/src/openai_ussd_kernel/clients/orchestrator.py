"""gRPC client for the Go Orchestrator service."""

import os
import threading
from typing import Any

import grpc

from openai_ussd_kernel.clients.exceptions import OrchestratorError, RateLimitError, SessionTimeoutError
from openai_ussd_kernel.clients.interceptors import TracingInterceptor
from openai_ussd_kernel.gateway.config import settings
from openai_ussd_kernel.infrastructure.observability import get_trace_id, set_trace_id, ussd_orchestrator_calls_total
from openai_ussd_kernel.protos.v1.common import common_pb2
from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2, orchestrator_pb2_grpc

_STATUS_CODE_MAP = {
    grpc.StatusCode.DEADLINE_EXCEEDED: SessionTimeoutError,
    grpc.StatusCode.UNAVAILABLE: OrchestratorError,
    grpc.StatusCode.PERMISSION_DENIED: OrchestratorError,
    grpc.StatusCode.UNAUTHENTICATED: OrchestratorError,
    grpc.StatusCode.RESOURCE_EXHAUSTED: RateLimitError,
}


def _inject_trace_metadata(metadata: list) -> list:
    """Ensure x-trace-id is present in outgoing metadata."""
    if not any(key == "x-trace-id" for key, _ in metadata):
        metadata.append(("x-trace-id", get_trace_id()))
    return metadata


class OrchestratorClient:
    """Singleton wrapper around the generated OrchestratorStub."""

    _instance: "OrchestratorClient | None" = None
    _lock = threading.Lock()

    def __new__(cls, *args: Any, **kwargs: Any) -> "OrchestratorClient":
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self, address: str | None = None):
        if self._initialized:
            return
        self._address = address or settings.orchestrator_addr

        # mTLS support: check for TLS_CERT_FILE, TLS_KEY_FILE, TLS_CA_FILE env vars
        tls_cert = os.environ.get("TLS_CERT_FILE", "")
        tls_key = os.environ.get("TLS_KEY_FILE", "")
        tls_ca = os.environ.get("TLS_CA_FILE", "")

        if tls_cert and tls_key and tls_ca and os.path.exists(tls_cert) and os.path.exists(tls_key) and os.path.exists(tls_ca):
            with open(tls_ca, "rb") as f:
                root_ca = f.read()
            with open(tls_key, "rb") as f:
                private_key = f.read()
            with open(tls_cert, "rb") as f:
                cert_chain = f.read()
            credentials = grpc.ssl_channel_credentials(
                root_certificates=root_ca,
                private_key=private_key,
                certificate_chain=cert_chain,
            )
            base_channel = grpc.secure_channel(
                self._address,
                credentials,
                options=[
                    ("grpc.keepalive_time_ms", 10000),
                    ("grpc.keepalive_timeout_ms", 5000),
                    ("grpc.http2.max_pings_without_data", 0),
                    ("grpc.http2.min_time_between_pings_ms", 10000),
                ],
            )
        else:
            base_channel = grpc.insecure_channel(self._address, options=[
                ("grpc.keepalive_time_ms", 10000),
                ("grpc.keepalive_timeout_ms", 5000),
                ("grpc.http2.max_pings_without_data", 0),
                ("grpc.http2.min_time_between_pings_ms", 10000),
            ])

        self._channel = grpc.intercept_channel(base_channel, TracingInterceptor())
        self._stub = orchestrator_pb2_grpc.OrchestratorStub(self._channel)
        self._initialized = True

    @classmethod
    def reset_instance(cls) -> None:
        """Reset the singleton instance (useful for testing)."""
        with cls._lock:
            cls._instance = None

    def _handle_error(self, exc: grpc.RpcError) -> None:
        """Map gRPC errors to custom exceptions."""
        code = exc.code()
        mapped = _STATUS_CODE_MAP.get(code, OrchestratorError)
        raise mapped(str(exc.details() or exc), grpc_code=code.value[0])

    def forward_ussd(
        self,
        session_id: str,
        phone_number: str,
        text: str,
        service_code: str,
        network_code: str,
        language_code: str = "en",
    ) -> orchestrator_pb2.ForwardUSSDResponse:
        """Call Orchestrator.ForwardUSSD with a populated request."""
        session = common_pb2.SessionContext(
            session_id=session_id,
            phone_number=phone_number,
            preferred_language=language_code,
            metadata={"network_code": network_code or "", "service_code": service_code or ""},
        )
        request = orchestrator_pb2.ForwardUSSDRequest(
            session=session,
            user_input=text,
            service_code=service_code,
        )
        try:
            return self._stub.ForwardUSSD(request, timeout=5)
        except grpc.RpcError as exc:
            ussd_orchestrator_calls_total.labels(method="ForwardUSSD", status="error").inc()
            self._handle_error(exc)
        finally:
            # Increment success if no exception was raised
            pass
        # unreachable

    def append_event(
        self,
        event_type: str,
        aggregate_type: str,
        aggregate_id: str,
        payload: dict,
    ) -> orchestrator_pb2.AppendEventResponse:
        """Call Orchestrator.AppendEvent."""
        request = orchestrator_pb2.AppendEventRequest(
            event_type=event_type,
            aggregate_type=aggregate_type,
            aggregate_id=aggregate_id,
        )
        try:
            return self._stub.AppendEvent(request, timeout=5)
        except grpc.RpcError as exc:
            ussd_orchestrator_calls_total.labels(method="AppendEvent", status="error").inc()
            self._handle_error(exc)

    def health(self) -> common_pb2.HealthResponse:
        """Call Orchestrator.Health."""
        request = common_pb2.HealthRequest()
        try:
            return self._stub.Health(request, timeout=2)
        except grpc.RpcError as exc:
            ussd_orchestrator_calls_total.labels(method="Health", status="error").inc()
            self._handle_error(exc)


# Monkey-patch ForwardUSSD to record success metric after the fact
_original_forward_ussd = OrchestratorClient.forward_ussd


def _forward_ussd_with_metrics(
    self,
    session_id: str,
    phone_number: str,
    text: str,
    service_code: str,
    network_code: str,
    language_code: str = "en",
) -> orchestrator_pb2.ForwardUSSDResponse:
    resp = _original_forward_ussd(
        self, session_id, phone_number, text, service_code, network_code, language_code
    )
    ussd_orchestrator_calls_total.labels(method="ForwardUSSD", status="success").inc()
    return resp


OrchestratorClient.forward_ussd = _forward_ussd_with_metrics

_original_append_event = OrchestratorClient.append_event


def _append_event_with_metrics(
    self,
    event_type: str,
    aggregate_type: str,
    aggregate_id: str,
    payload: dict,
) -> orchestrator_pb2.AppendEventResponse:
    resp = _original_append_event(self, event_type, aggregate_type, aggregate_id, payload)
    ussd_orchestrator_calls_total.labels(method="AppendEvent", status="success").inc()
    return resp


OrchestratorClient.append_event = _append_event_with_metrics

_original_health = OrchestratorClient.health


def _health_with_metrics(self) -> common_pb2.HealthResponse:
    resp = _original_health(self)
    ussd_orchestrator_calls_total.labels(method="Health", status="success").inc()
    return resp


OrchestratorClient.health = _health_with_metrics
