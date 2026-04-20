"""Intent detection domain types."""
from dataclasses import dataclass
from enum import Enum
from typing import Optional


class IntentType(str, Enum):
    CHECK_BALANCE = "check_balance"
    SEND_MONEY = "send_money"
    PAY_BILL = "pay_bill"
    BUY_AIRTIME = "buy_airtime"
    REGISTER = "register"
    COMPLAINT = "complaint"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class Intent:
    intent_type: IntentType
    confidence: float
    entities: dict[str, str]
    raw_input: str

    def __post_init__(self):
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError("confidence must be between 0.0 and 1.0")
