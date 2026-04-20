"""USSD request domain types."""
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class UssdRequest:
    session_id: str
    phone_number: str
    text: str
    service_code: str
    network_code: Optional[str] = None
    language: str = "en"

    def __post_init__(self):
        if not self.session_id:
            raise ValueError("session_id is required")
        if not self.phone_number:
            raise ValueError("phone_number is required")
        if self.text is None:
            raise ValueError("text is required")
