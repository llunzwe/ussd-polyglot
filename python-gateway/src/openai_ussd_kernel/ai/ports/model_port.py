"""Model inference port interface."""
from abc import ABC, abstractmethod
from typing import Protocol

from openai_ussd_kernel.ai.domain.intent import Intent
from openai_ussd_kernel.ai.domain.personalization import PersonalizedResult, UserContext
from openai_ussd_kernel.ai.domain.translation import TranslationRequest, TranslationResult


class ModelInferencePort(Protocol):
    """Port for AI model inference operations."""

    def translate(self, request: TranslationRequest) -> TranslationResult:
        ...

    def personalize(self, menu_text: str, context: UserContext) -> PersonalizedResult:
        ...

    def detect_intent(self, input_text: str, session_context: dict) -> Intent:
        ...

    def summarize_session(self, events: list[dict]) -> dict:
        ...

    def get_embedding(self, text: str) -> list[float]:
        ...
