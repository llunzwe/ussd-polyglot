"""Personalization domain types."""
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class UserContext:
    phone_number: str
    tenant_id: str
    session_id: Optional[str] = None
    language: str = "en"
    preferences: dict[str, str] = None
    history: list[str] = None

    def __post_init__(self):
        object.__setattr__(self, "preferences", self.preferences or {})
        object.__setattr__(self, "history", self.history or [])


@dataclass(frozen=True)
class PersonalizedResult:
    original_text: str
    personalized_text: str
    hints_added: list[str]
    user_context: UserContext
