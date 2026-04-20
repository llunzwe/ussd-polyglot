"""Decorators for the Tenant SDK."""

from functools import wraps
from typing import Callable


class _UssdDecorators:
    """Namespace for USSD-related decorators."""

    @staticmethod
    def menu(route: str = "main") -> Callable:
        """Mark a function as a USSD menu handler for a given route."""
        def decorator(func: Callable) -> Callable:
            func._ussd_route = route  # type: ignore[attr-defined]
            @wraps(func)
            def wrapper(*args, **kwargs):
                return func(*args, **kwargs)
            wrapper._ussd_route = route  # type: ignore[attr-defined]
            return wrapper
        return decorator


class _SessionDecorators:
    """Namespace for session-related decorators."""

    @staticmethod
    def persist(key: str = "state_key") -> Callable:
        """Stub decorator that hints session persistence for a given state key."""
        def decorator(func: Callable) -> Callable:
            func._session_persist_key = key  # type: ignore[attr-defined]
            @wraps(func)
            def wrapper(*args, **kwargs):
                return func(*args, **kwargs)
            wrapper._session_persist_key = key  # type: ignore[attr-defined]
            return wrapper
        return decorator


ussd = _UssdDecorators()
session = _SessionDecorators()
