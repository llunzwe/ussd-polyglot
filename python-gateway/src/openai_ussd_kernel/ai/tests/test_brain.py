"""Tests for AIBrain."""

import pytest

from openai_ussd_kernel.ai.brain import AIBrain


@pytest.fixture
def brain():
    return AIBrain()


def test_translate_shona(brain):
    assert brain.translate("Welcome", "sn") == "Mauya"


def test_translate_ndebele(brain):
    assert brain.translate("Welcome", "nd") == "Wamukelekile"


def test_translate_english_passthrough(brain):
    assert brain.translate("Welcome", "en") == "Welcome"


def test_translate_unknown_language_fallback(brain):
    result = brain.translate("Hello", "xx")
    assert result.startswith("[xx]")


def test_translate_no_dictionary_fallback(brain):
    result = brain.translate("Unicorn", "sn")
    assert result.startswith("[sn]")


def test_personalize_with_hints(brain):
    result = brain.personalize("Main Menu", {"preferred_language": "sn", "balance": 50})
    assert "Main Menu" in result
    assert "Lang auto-detected" in result
    assert "Balance: 50" in result


def test_personalize_no_hints(brain):
    result = brain.personalize("Main Menu", {})
    assert result == "Main Menu"


def test_detect_intent_known(brain):
    result = brain.detect_intent("1")
    assert result["intent"] == "select_option"
    assert result["confidence"] == 0.95


def test_detect_intent_unknown(brain):
    result = brain.detect_intent("xyz")
    assert result["intent"] == "unknown"
    assert result["confidence"] == 0.50


def test_summarize_session_empty(brain):
    result = brain.summarize_session([])
    assert result["summary"] == "No events recorded."
    assert result["key_actions"] == []


def test_summarize_session_with_events(brain):
    events = [
        {"menu": "main", "type": "navigation"},
        {"menu": "balance", "type": "payment"},
    ]
    result = brain.summarize_session(events)
    assert "2 event(s)" in result["summary"]
    assert "Payment initiated" in result["key_actions"]
