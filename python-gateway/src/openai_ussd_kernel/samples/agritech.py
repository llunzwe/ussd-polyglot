"""Sample agritech tenant app using the Tenant SDK."""

from openai_ussd_kernel.sdk import UssdApp, MenuContext, UssdResponse, MenuOption
from openai_ussd_kernel.sdk.decorators import ussd


class AgritechApp(UssdApp):
    """Agritech tenant application demo."""

    def __init__(self) -> None:
        super().__init__(tenant_id="agritech-demo")

    @ussd.menu(route="main")
    def main_menu(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Welcome to AgriTech. How can we help?",
            type="CON",
            options=[
                MenuOption(id="1", label="Weather Forecast", action="weather"),
                MenuOption(id="2", label="Market Prices", action="prices"),
                MenuOption(id="3", label="Input Suppliers", action="suppliers"),
            ],
        )

    @ussd.menu(route="weather")
    def weather_forecast(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Expect light rains tomorrow. 0. Back",
            type="CON",
            options=[MenuOption(id="0", label="Back", target_menu="main")],
        )

    @ussd.menu(route="prices")
    def market_prices(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Maize: $0.35/kg\nSoya: $0.52/kg\n0. Back",
            type="CON",
            options=[MenuOption(id="0", label="Back", target_menu="main")],
        )

    @ussd.menu(route="suppliers")
    def input_suppliers(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Nearest supplier: FarmInputs Harare. Call 0242-123456.",
            type="END",
        )
