"""USSD request handlers for Africa's Talking callbacks."""

import logging
import time
from threading import Lock

from openai_ussd_kernel.ai.brain import AIBrain
from openai_ussd_kernel.clients.exceptions import OrchestratorError, RateLimitError, SessionTimeoutError
from openai_ussd_kernel.clients.orchestrator import OrchestratorClient
from openai_ussd_kernel.gateway.config import settings
from openai_ussd_kernel.gateway.models import UssdRequest
from openai_ussd_kernel.infrastructure.observability import get_trace_id, ussd_requests_total
from openai_ussd_kernel.infrastructure.redis_client import get_redis

logger = logging.getLogger("python-gateway")


class _TokenBucket:
    """In-memory token bucket for per-phone-number rate limiting (fallback)."""

    def __init__(self, max_tokens: float, window_seconds: float = 60.0):
        self.max_tokens = max_tokens
        self.window_seconds = window_seconds
        self._buckets: dict[str, tuple[float, float]] = {}  # phone -> (tokens, last_update)
        self._lock = Lock()

    def allow(self, key: str) -> bool:
        now = time.time()
        with self._lock:
            tokens, last = self._buckets.get(key, (self.max_tokens, now))
            elapsed = now - last
            tokens = min(self.max_tokens, tokens + elapsed * (self.max_tokens / self.window_seconds))
            if tokens >= 1.0:
                self._buckets[key] = (tokens - 1.0, now)
                return True
            self._buckets[key] = (tokens, now)
            return False

    def clear(self, key: str) -> None:
        with self._lock:
            self._buckets.pop(key, None)


class _SessionTracker:
    """In-memory session activity tracker for timeout detection (fallback)."""

    def __init__(self, timeout_seconds: float = 180.0):
        self.timeout_seconds = timeout_seconds
        self._activity: dict[str, float] = {}
        self._lock = Lock()

    def touch(self, session_id: str) -> bool:
        """Update activity timestamp. Returns False if session timed out."""
        now = time.time()
        with self._lock:
            last = self._activity.get(session_id)
            if last is not None and (now - last) > self.timeout_seconds:
                return False
            self._activity[session_id] = now
            return True

    def clear(self, session_id: str) -> None:
        with self._lock:
            self._activity.pop(session_id, None)


class _RedisRateLimiter:
    """Redis-backed sliding-window rate limiter."""

    def __init__(self, max_tokens: float, window_seconds: float = 60.0):
        self.max_tokens = max_tokens
        self.window_seconds = window_seconds
        self._redis = get_redis()
        self._fallback = _TokenBucket(max_tokens, window_seconds)

    def allow(self, key: str) -> bool:
        if not self._redis.available:
            return self._fallback.allow(key)

        now = time.time()
        window_start = now - self.window_seconds
        redis_key = f"rate_limit:{key}"
        pipe = self._redis.client.pipeline()
        pipe.zremrangebyscore(redis_key, 0, window_start)
        pipe.zcard(redis_key)
        pipe.zadd(redis_key, {str(now): now})
        pipe.expire(redis_key, int(self.window_seconds) + 1)
        results = pipe.execute()
        count = results[1]
        if count >= self.max_tokens:
            # Remove the entry we just added since request is denied
            self._redis.client.zrem(redis_key, str(now))
            return False
        return True

    def clear(self, key: str) -> None:
        if self._redis.available:
            self._redis.client.delete(f"rate_limit:{key}")
        self._fallback.clear(key)


class _RedisSessionTracker:
    """Redis-backed session activity tracker with TTL."""

    def __init__(self, timeout_seconds: float = 180.0):
        self.timeout_seconds = timeout_seconds
        self._redis = get_redis()
        self._fallback = _SessionTracker(timeout_seconds)

    def touch(self, session_id: str) -> bool:
        if not self._redis.available:
            return self._fallback.touch(session_id)

        redis_key = f"session:{session_id}"
        last_str = self._redis.client.get(redis_key)
        now = time.time()
        if last_str is not None:
            last = float(last_str)
            if (now - last) > self.timeout_seconds:
                return False
        self._redis.client.setex(redis_key, int(self.timeout_seconds), str(now))
        return True

    def clear(self, session_id: str) -> None:
        if self._redis.available:
            self._redis.client.delete(f"session:{session_id}")
        self._fallback.clear(session_id)


_rate_limiter = _RedisRateLimiter(max_tokens=settings.rate_limit_rps, window_seconds=60.0)
_session_tracker = _RedisSessionTracker(timeout_seconds=180.0)
_orchestrator = OrchestratorClient()
_ai_brain = AIBrain()


def ussd_callback(request: UssdRequest) -> str:
    """Handle an Africa's Talking USSD callback.

    Validates input, applies rate limiting and session timeout checks,
    forwards to the Go Orchestrator, and formats the Africa's Talking response.
    """
    # Validate required fields
    if not request.session_id or not request.phone_number or request.text is None or not request.service_code:
        ussd_requests_total.labels(service_code=request.service_code or "unknown", status="invalid").inc()
        return "END Invalid request. Missing required fields."

    # Rate limiting
    if not _rate_limiter.allow(request.phone_number):
        ussd_requests_total.labels(service_code=request.service_code, status="rate_limited").inc()
        return "END You have made too many requests. Please try again later."

    # Session timeout check
    active = _session_tracker.touch(request.session_id)
    if not active:
        _session_tracker.clear(request.session_id)
        ussd_requests_total.labels(service_code=request.service_code, status="timeout").inc()
        return "END Your session has timed out. Please dial again."

    try:
        grpc_response = _orchestrator.forward_ussd(
            session_id=request.session_id,
            phone_number=request.phone_number,
            text=request.text,
            service_code=request.service_code,
            network_code=request.network_code,
            language_code=settings.default_language,
        )
    except RateLimitError:
        ussd_requests_total.labels(service_code=request.service_code, status="rate_limited").inc()
        return "END You have made too many requests. Please try again later."
    except SessionTimeoutError:
        _session_tracker.clear(request.session_id)
        ussd_requests_total.labels(service_code=request.service_code, status="timeout").inc()
        return "END Your session has timed out. Please dial again."
    except OrchestratorError:
        ussd_requests_total.labels(service_code=request.service_code, status="error").inc()
        return "END An error occurred. Please try again."

    # Determine user language from updated_state or default
    language = settings.default_language
    if grpc_response.updated_state and grpc_response.updated_state.fields:
        lang_field = grpc_response.updated_state.fields.get("language")
        if lang_field and lang_field.string_value:
            language = lang_field.string_value

    # Map gRPC response type to Africa's Talking prefix
    prefix = "CON" if grpc_response.type == 0 else "END"
    menu_text = grpc_response.menu_text or "Thank you for using our service."

    # AI Translation for non-English languages
    if language in _ai_brain.SUPPORTED_LANGUAGES and language != "en":
        menu_text = _ai_brain.translate(menu_text, language)

    # AI Personalization based on updated_state context
    user_context = {}
    if grpc_response.updated_state and grpc_response.updated_state.fields:
        for key, value in grpc_response.updated_state.fields.items():
            if value.HasField("string_value"):
                user_context[key] = value.string_value
            elif value.HasField("number_value"):
                user_context[key] = value.number_value
    if user_context:
        menu_text = _ai_brain.personalize(menu_text, user_context)

    # Append options if present
    lines = [menu_text]
    for option in grpc_response.options:
        label = option.label or option.id
        if language in _ai_brain.SUPPORTED_LANGUAGES and language != "en":
            label = _ai_brain.translate(label, language)
        lines.append(f"{option.id}. {label}")

    body = "\n".join(lines)

    ussd_requests_total.labels(service_code=request.service_code, status="success").inc()
    logger.info(
        "ussd_callback processed",
        extra={
            "attributes": {
                "event": "ussd_callback",
                "session_id": request.session_id,
                "phone_number": request.phone_number,
                "trace_id": get_trace_id(),
            }
        },
    )
    return f"{prefix} {body}"
