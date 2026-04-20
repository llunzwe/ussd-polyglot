"""Pydantic models for the Tenant SDK."""

from typing import Any
from pydantic import BaseModel, Field


class MenuOption(BaseModel):
    """A single menu option."""

    id: str
    label: str
    action: str = ""
    target_menu: str = Field(alias="targetMenu", default="")

    model_config = {"populate_by_name": True}


class PaymentResult(BaseModel):
    """Result of a payment operation."""

    success: bool
    transaction_id: str = Field(alias="transactionId", default="")
    message: str = ""
    amount: dict[str, Any] = Field(default_factory=dict)

    model_config = {"populate_by_name": True}


class UssdResponse(BaseModel):
    """Response returned by a tenant menu handler."""

    message: str
    type: str = "CON"  # "CON" or "END"
    options: list[MenuOption] = Field(default_factory=list)

    model_config = {"populate_by_name": True}
