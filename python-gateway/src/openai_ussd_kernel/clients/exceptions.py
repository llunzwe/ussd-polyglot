"""Custom exceptions for gRPC client interactions."""


class OrchestratorError(Exception):
    """Raised when the orchestrator returns an error or is unreachable."""

    def __init__(self, message: str, grpc_code: int | None = None):
        super().__init__(message)
        self.message = message
        self.grpc_code = grpc_code


class RateLimitError(Exception):
    """Raised when a request exceeds the permitted rate limit."""

    def __init__(self, message: str = "Rate limit exceeded", grpc_code: int | None = None):
        super().__init__(message)
        self.message = message
        self.grpc_code = grpc_code


class SessionTimeoutError(Exception):
    """Raised when a USSD session has exceeded the timeout threshold."""

    def __init__(self, message: str = "Session timed out", grpc_code: int | None = None):
        super().__init__(message)
        self.message = message
        self.grpc_code = grpc_code
