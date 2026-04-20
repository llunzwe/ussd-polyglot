"""Pydantic models for AI Brain requests and responses."""

from pydantic import BaseModel, Field


class TranslateRequest(BaseModel):
    """Request to translate text."""

    text: str
    target_language: str = Field(alias="targetLanguage")

    model_config = {"populate_by_name": True}


class TranslateResponse(BaseModel):
    """Result of a translation request."""

    translated_text: str = Field(alias="translatedText")
    source_text: str = Field(alias="sourceText")
    target_language: str = Field(alias="targetLanguage")

    model_config = {"populate_by_name": True}


class PersonalizeRequest(BaseModel):
    """Request to personalize menu text."""

    menu_text: str = Field(alias="menuText")
    user_context: dict = Field(alias="userContext")

    model_config = {"populate_by_name": True}


class PersonalizeResponse(BaseModel):
    """Result of a personalization request."""

    personalized_text: str = Field(alias="personalizedText")

    model_config = {"populate_by_name": True}


class IntentRequest(BaseModel):
    """Request to detect user intent."""

    text: str


class IntentResponse(BaseModel):
    """Result of an intent detection request."""

    intent: str
    confidence: float = Field(ge=0.0, le=1.0)


class SummarizeRequest(BaseModel):
    """Request to summarize a session."""

    events: list[dict]


class SummarizeResponse(BaseModel):
    """Result of a session summarization request."""

    summary: str
    key_actions: list[str] = Field(alias="keyActions")

    model_config = {"populate_by_name": True}
