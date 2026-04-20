"""Tests for UssdApp subclass behavior."""

import pytest

from openai_ussd_kernel.sdk import UssdApp, MenuContext, UssdResponse, PaymentResult
from openai_ussd_kernel.sdk.decorators import ussd


class DemoApp(UssdApp):
    def __init__(self):
        super().__init__(tenant_id="demo")

    @ussd.menu(route="main")
    def main_menu(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(message="Hello", type="CON")

    @ussd.menu(route="about")
    def about_menu(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(message="About us", type="END")


def test_route_registration():
    app = DemoApp()
    assert "main" in app._routes
    assert "about" in app._routes


def test_handle_menu_main():
    app = DemoApp()
    ctx = MenuContext(
        sessionId="s1",
        phoneNumber="+263771000001",
        userInput="",
        currentMenu="main",
    )
    resp = app.handle_menu(ctx)
    assert resp.message == "Hello"
    assert resp.type == "CON"


def test_handle_menu_invalid():
    app = DemoApp()
    ctx = MenuContext(
        sessionId="s1",
        phoneNumber="+263771000001",
        userInput="",
        currentMenu="missing",
    )
    resp = app.handle_menu(ctx)
    assert resp.type == "END"
    assert "Invalid" in resp.message


def test_on_payment_confirmation_success():
    app = DemoApp()
    ctx = MenuContext(
        sessionId="s1",
        phoneNumber="+263771000001",
        userInput="",
        currentMenu="main",
    )
    result = PaymentResult(success=True, message="Paid")
    resp = app.on_payment_confirmation(ctx, result)
    assert resp.type == "END"
    assert "successful" in resp.message


def test_on_payment_confirmation_failure():
    app = DemoApp()
    ctx = MenuContext(
        sessionId="s1",
        phoneNumber="+263771000001",
        userInput="",
        currentMenu="main",
    )
    result = PaymentResult(success=False, message="Failed")
    resp = app.on_payment_confirmation(ctx, result)
    assert resp.type == "CON"
    assert "failed" in resp.message
