"""
gRPC interceptors for the Python USSD Gateway.

Injects OpenTelemetry trace context and request metadata (request_id, auth_token)
into outgoing unary calls.
"""

import uuid
from typing import Callable

import grpc

from openai_ussd_kernel.infrastructure.observability import get_trace_id


class TracingInterceptor(grpc.UnaryUnaryClientInterceptor):
    """Injects trace context and request metadata into every outgoing gRPC call."""

    def intercept_unary_unary(
        self,
        continuation: Callable,
        client_call_details: grpc.ClientCallDetails,
        request,
    ):
        metadata = list(client_call_details.metadata or [])

        # Inject request_id if absent (use UUIDv7 in production if available)
        if not any(key == "x-request-id" for key, _ in metadata):
            metadata.append(("x-request-id", str(uuid.uuid4())))

        # Inject trace_id if absent
        if not any(key == "x-trace-id" for key, _ in metadata):
            metadata.append(("x-trace-id", get_trace_id()))

        # Inject authorization placeholder if absent
        if not any(key == "authorization" for key, _ in metadata):
            # In production, extract JWT or API key from application context
            pass

        class _UpdatedClientCallDetails(grpc.ClientCallDetails):
            @property
            def method(self):
                return client_call_details.method
            @property
            def timeout(self):
                return client_call_details.timeout
            @property
            def metadata(self):
                return metadata
            @property
            def credentials(self):
                return client_call_details.credentials

        return continuation(_UpdatedClientCallDetails(), request)
