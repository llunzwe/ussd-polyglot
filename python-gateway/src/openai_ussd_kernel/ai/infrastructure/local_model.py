"""Local model adapter — wraps the existing AIBrain class."""
import logging
import os

from openai_ussd_kernel.ai.brain import AIBrain
from openai_ussd_kernel.ai.domain.intent import Intent, IntentType
from openai_ussd_kernel.ai.domain.personalization import PersonalizedResult, UserContext
from openai_ussd_kernel.ai.domain.translation import TranslationRequest, TranslationResult

logger = logging.getLogger(__name__)


class LocalModelAdapter:
    """Adapter that wraps the dictionary-based AIBrain as a ModelInferencePort.

    Uses LlamaModelAdapter for translate/intent when LLAMA_MODEL_PATH is set.
    """

    def __init__(self) -> None:
        self._brain = AIBrain()
        self._llama = None
        model_path = os.environ.get("LLAMA_MODEL_PATH")
        if model_path:
            try:
                from openai_ussd_kernel.ai.infrastructure.llama_model import LlamaModelAdapter
                self._llama = LlamaModelAdapter(model_path)
                logger.info("Loaded LlamaModelAdapter from %s", model_path)
            except Exception as exc:
                logger.warning("Failed to load LlamaModelAdapter: %s", exc)

    def translate(self, request: TranslationRequest) -> TranslationResult:
        if self._llama is not None:
            translated = self._llama.translate(request.text, request.target_language)
            confidence = 0.92
        else:
            translated = self._brain.translate(request.text, request.target_language)
            confidence = 0.85
        return TranslationResult(
            original_text=request.text,
            translated_text=translated,
            source_language=request.source_language or "en",
            target_language=request.target_language,
            confidence=confidence,
        )

    def personalize(self, menu_text: str, context: UserContext) -> PersonalizedResult:
        user_ctx_dict = {
            "phone_number": context.phone_number,
            "language": context.language,
            **context.preferences,
        }
        personalized = self._brain.personalize(menu_text, user_ctx_dict)
        hints = []
        if context.language in self._brain.SUPPORTED_LANGUAGES and context.language != "en":
            hints.append(f"localized_{context.language}")
        return PersonalizedResult(
            original_text=menu_text,
            personalized_text=personalized,
            hints_added=hints,
            user_context=context,
        )

    def detect_intent(self, input_text: str, session_context: dict) -> Intent:
        if self._llama is not None:
            result = self._llama.detect_intent(input_text)
        else:
            result = self._brain.detect_intent(input_text)
        intent_type = IntentType.UNKNOWN
        try:
            intent_type = IntentType(result.get("intent", "unknown"))
        except ValueError:
            pass
        return Intent(
            intent_type=intent_type,
            confidence=result.get("confidence", 0.5),
            entities=result.get("entities", {}),
            raw_input=input_text,
        )

    def summarize_session(self, events: list[dict]) -> dict:
        return self._brain.summarize_session(events)

    def get_embedding(self, text: str) -> list[float]:
        """Stub embedding — returns a simple hash-based vector."""
        # In production, this would call a real embedding model
        import hashlib
        h = hashlib.sha256(text.encode()).hexdigest()
        vec = [int(h[i : i + 2], 16) / 255.0 for i in range(0, 64, 2)]
        return vec

    def list_models(self) -> list[dict]:
        return [
            {
                "model_id": "ai-brain-v1",
                "version": "1.0.0",
                "language": "en/sn/nd",
                "status": "active",
            }
        ]

    def get_model_info(self, model_id: str) -> dict:
        return {
            "model_id": model_id,
            "version": "1.0.0",
            "language": "en/sn/nd",
            "status": "active",
        }
