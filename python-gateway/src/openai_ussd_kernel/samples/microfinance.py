"""Sample microfinance tenant app using the Tenant SDK."""

from openai_ussd_kernel.sdk import UssdApp, MenuContext, UssdResponse, MenuOption
from openai_ussd_kernel.sdk.decorators import ussd


class MicrofinanceApp(UssdApp):
    """Microfinance tenant application demo."""

    def __init__(self) -> None:
        super().__init__(tenant_id="microfinance-demo")

    @ussd.menu(route="main")
    def main_menu(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Welcome to MicroFinance. Choose an option:",
            type="CON",
            options=[
                MenuOption(id="1", label="Check Balance", action="balance"),
                MenuOption(id="2", label="Apply for Loan", action="loan"),
                MenuOption(id="3", label="Repay Loan", action="repay"),
            ],
        )

    @ussd.menu(route="balance")
    def check_balance(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Your balance is $125.00 USD.\n0. Back",
            type="CON",
            options=[MenuOption(id="0", label="Back", target_menu="main")],
        )

    @ussd.menu(route="loan")
    def apply_loan(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Loan application submitted. You will receive an SMS shortly.",
            type="END",
        )

    @ussd.menu(route="repay")
    def repay_loan(self, ctx: MenuContext) -> UssdResponse:
        return UssdResponse(
            message="Enter amount to repay:",
            type="CON",
        )
