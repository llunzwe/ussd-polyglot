"""MenuContext for tenant menu handlers."""

from pydantic import BaseModel, Field


class MenuContext(BaseModel):
    """Context passed to every USSD menu handler."""

    session_id: str = Field(alias="sessionId")
    phone_number: str = Field(alias="phoneNumber")
    user_input: str = Field(alias="userInput")
    current_menu: str = Field(alias="currentMenu")
    session_state: dict = Field(alias="sessionState", default_factory=dict)
    language_code: str = Field(alias="languageCode", default="en")

    model_config = {"populate_by_name": True}
