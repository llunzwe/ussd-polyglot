"""Translation domain types."""
from dataclasses import dataclass


@dataclass(frozen=True)
class TranslationRequest:
    text: str
    source_language: str
    target_language: str
    tenant_id: str


@dataclass(frozen=True)
class TranslationResult:
    original_text: str
    translated_text: str
    source_language: str
    target_language: str
    confidence: float
