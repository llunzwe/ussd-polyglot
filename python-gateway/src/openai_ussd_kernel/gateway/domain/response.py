"""USSD response domain types."""
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class UssdResponse:
    text: str
    is_end: bool = False
    options: list[str] = None
    next_menu: Optional[str] = None

    def __post_init__(self):
        object.__setattr__(self, "options", self.options or [])
