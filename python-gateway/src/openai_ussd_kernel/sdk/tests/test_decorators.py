"""Tests for Tenant SDK decorators."""

from openai_ussd_kernel.sdk.decorators import ussd, session


def test_ussd_menu_decorator():
    @ussd.menu(route="main")
    def main_menu():
        return "main"

    assert hasattr(main_menu, "_ussd_route")
    assert main_menu._ussd_route == "main"
    assert main_menu() == "main"


def test_session_persist_decorator():
    @session.persist(key="user_state")
    def save_state():
        return "saved"

    assert hasattr(save_state, "_session_persist_key")
    assert save_state._session_persist_key == "user_state"
    assert save_state() == "saved"
