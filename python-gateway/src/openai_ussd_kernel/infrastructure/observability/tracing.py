"""Trace context helpers using contextvars."""

import contextvars
import uuid

_trace_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("trace_id")


def get_trace_id() -> str:
    """Return the current trace ID or generate a new UUIDv4."""
    try:
        return _trace_id_var.get()
    except LookupError:
        trace_id = str(uuid.uuid4())
        _trace_id_var.set(trace_id)
        return trace_id


def set_trace_id(trace_id: str) -> None:
    """Store a trace ID in the current async context."""
    _trace_id_var.set(trace_id)
