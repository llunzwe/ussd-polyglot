"""Sample health services tenant app using the Tenant SDK."""

from openai_ussd_kernel.sdk import UssdApp, MenuContext, UssdResponse, MenuOption
from openai_ussd_kernel.sdk.decorators import ussd


class HealthApp(UssdApp):
    """Health services tenant application demo."""

    def __init__(self) -> None:
        super().__init__(tenant_id="health-demo")

    @ussd.menu(route="main")
    def main_menu(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Welcome to HealthConnect. Select a service:",
            type="CON",
            options=[
                MenuOption(id="1", label="Find Nearest Clinic", action="clinic"),
                MenuOption(id="2", label="Book Appointment", action="appointment"),
                MenuOption(id="3", label="Emergency Hotline", action="emergency"),
            ],
        )

    @ussd.menu(route="clinic")
    def find_clinic(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Nearest clinic: City Clinic (1.2km). Open 24hrs.",
            type="END",
        )

    @ussd.menu(route="appointment")
    def book_appointment(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Appointment request received. Ref: APT-8821.",
            type="END",
        )

    @ussd.menu(route="emergency")
    def emergency_hotline(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Dial 999 for emergencies or 112 from mobile.",
            type="END",
        )
