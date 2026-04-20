"""AI Brain for translation, personalization, intent detection, and summarization."""

import re
from typing import Literal

from openai_ussd_kernel.ai.dictionaries import DICTIONARIES
from openai_ussd_kernel.infrastructure.observability import ai_translations_total


class AIBrain:
    """Stub AI brain for USSD personalization and translation."""

    SUPPORTED_LANGUAGES = {"sn", "nd", "en"}

    def translate(self, text: str, target_language: str) -> str:
        """Translate text using dictionary fallbacks for Shona and Ndebele.

        If no dictionary entry exists, returns the original text with a [lang] prefix.
        """
        ai_translations_total.labels(target_language=target_language).inc()

        if target_language == "en" or not text:
            return text

        dictionary = DICTIONARIES.get(target_language)
        if not dictionary:
            return f"[{target_language}] {text}"

        # Simple word/phrase replacement preserving case for known phrases
        result = text
        # Sort by length descending to match longer phrases first
        for phrase, translation in sorted(dictionary.items(), key=lambda x: len(x[0]), reverse=True):
            # Use word boundaries for standalone words, or simple replacement for phrases
            escaped = re.escape(phrase)
            result = re.sub(rf"\b{escaped}\b", translation, result)
        # If nothing changed, add prefix
        if result == text:
            return f"[{target_language}] {text}"
        return result

    def personalize(self, menu_text: str, user_context: dict) -> str:
        """Append personalized hints based on user context."""
        hints: list[str] = []
        if user_context.get("preferred_language") and user_context.get("preferred_language") != "en":
            hints.append("[Lang auto-detected]")
        if user_context.get("last_menu"):
            hints.append(f"Last: {user_context['last_menu']}")
        if user_context.get("balance") is not None:
            hints.append(f"Balance: {user_context['balance']}")
        if hints:
            return f"{menu_text}\n-- {' | '.join(hints)}"
        return menu_text

    def detect_intent(self, text: str) -> dict:
        """Detect user intent from raw USSD input text."""
        lowered = text.strip().lower()
        intent_map: dict[str, tuple[str, float]] = {
            "1": ("select_option", 0.95),
            "2": ("select_option", 0.95),
            "3": ("select_option", 0.95),
            "0": ("go_back", 0.90),
            "00": ("go_home", 0.95),
            "send": ("transfer", 0.85),
            "pay": ("payment", 0.85),
            "balance": ("check_balance", 0.90),
            "help": ("request_help", 0.80),
            "exit": ("terminate_session", 0.95),
            "cancel": ("terminate_session", 0.85),
        }
        intent, confidence = intent_map.get(lowered, ("unknown", 0.50))
        return {"intent": intent, "confidence": confidence}

    def summarize_session(self, events: list[dict]) -> dict:
        """Summarize a list of session events."""
        if not events:
            return {"summary": "No events recorded.", "key_actions": []}
        menus_visited = {e.get("menu") for e in events if e.get("menu")}
        payments = [e for e in events if e.get("type") == "payment"]
        summary = f"Session with {len(events)} event(s)."
        if menus_visited:
            summary += f" Menus: {', '.join(sorted(menus_visited))}."
        if payments:
            summary += f" Payments: {len(payments)}."
        key_actions = []
        if payments:
            key_actions.append("Payment initiated")
        if menus_visited:
            key_actions.append("Menu navigation completed")
        return {"summary": summary, "key_actions": key_actions}
