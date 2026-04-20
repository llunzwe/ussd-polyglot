"""Pydantic models for USSD gateway requests and responses."""

from typing import Literal
from pydantic import BaseModel, Field


class UssdRequest(BaseModel):
    """Incoming Africa's Talking USSD request."""

    session_id: str = Field(alias="sessionId")
    phone_number: str = Field(alias="phoneNumber")
    text: str
    service_code: str = Field(alias="serviceCode")
    network_code: str = Field(alias="networkCode", default="")

    model_config = {"populate_by_name": True}


class UssdResponse(BaseModel):
    """Outgoing Africa's Talking USSD response."""

    message: str
    type: Literal["CON", "END"] = "CON"
    options: list[str] = Field(default_factory=list)
