"""Base UssdApp class for tenant developers."""

from typing import Any

from openai_ussd_kernel.sdk.context import MenuContext
from openai_ussd_kernel.sdk.models import PaymentResult, UssdResponse


class UssdApp:
    """Base class that tenant developers subclass to build USSD applications."""

    def __init__(self, tenant_id: str = ""):
        self.tenant_id = tenant_id
        self._routes: dict[str, Any] = {}
        self._register_routes()

    def _register_routes(self) -> None:
        """Auto-register methods decorated with @ussd.menu."""
        for attr_name in dir(self):
            attr = getattr(self, attr_name)
            if callable(attr) and hasattr(attr, "_ussd_route"):
                self._routes[attr._ussd_route] = attr

    def handle_menu(self, ctx: MenuContext) -> UssdResponse:
        """Dispatch to the registered menu handler for the current menu."""
        handler = self._routes.get(ctx.current_menu)
        if handler is None:
            return UssdResponse(message="Invalid menu selection.", type="END")
        return handler(ctx)

    def on_payment_confirmation(self, ctx: MenuContext, payment_result: PaymentResult) -> UssdResponse:
        """Called when a payment confirmation is received. Override in subclass."""
        return UssdResponse(
            message=f"Payment {'successful' if payment_result.success else 'failed'}: {payment_result.message}",
            type="CON" if not payment_result.success else "END",
        )
