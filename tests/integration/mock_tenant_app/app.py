"""Mock Tenant USSD App gRPC server for integration tests."""

import os
from concurrent import futures

import grpc

from protos.v1.tenant_application import tenant_application_pb2
from protos.v1.tenant_application import tenant_application_pb2_grpc
from protos.v1.common import common_pb2
from google.protobuf import struct_pb2


class MockTenantUSSDAppServicer(tenant_application_pb2_grpc.TenantUSSDAppServicer):
    def HandleMenu(self, request, context):
        user_input = request.user_input
        session_state = request.session_state
        state_map = dict(session_state.fields) if session_state else {}
        current_menu = state_map.get("current_menu", "")

        if not user_input and not current_menu:
            # Initial menu
            state = struct_pb2.Struct()
            state.fields["current_menu"].string_value = "main_menu"
            return tenant_application_pb2.MenuResponse(
                type=tenant_application_pb2.MenuResponse.CON,
                message="Welcome to Mock Bank. Choose an option:",
                options=[
                    tenant_application_pb2.MenuOption(id="1", label="Check Balance"),
                    tenant_application_pb2.MenuOption(id="2", label="Pay $10"),
                ],
                updated_state=state,
            )

        if user_input == "1" or current_menu == "check_balance":
            state = struct_pb2.Struct()
            state.fields["current_menu"].string_value = "done"
            state.fields["balance"].string_value = "$100.00"
            return tenant_application_pb2.MenuResponse(
                type=tenant_application_pb2.MenuResponse.END,
                message="Your balance is $100.00",
                updated_state=state,
            )

        if user_input == "2" or current_menu == "pay":
            state = struct_pb2.Struct()
            state.fields["current_menu"].string_value = "payment_initiated"
            state.fields["payment_status"].string_value = "pending"
            return tenant_application_pb2.MenuResponse(
                type=tenant_application_pb2.MenuResponse.CON,
                message="PaymentInitiated. Processing...",
                updated_state=state,
            )

        # Default fallback
        state = struct_pb2.Struct()
        state.fields["current_menu"].string_value = "main_menu"
        return tenant_application_pb2.MenuResponse(
            type=tenant_application_pb2.MenuResponse.CON,
            message="Welcome to Mock Bank. Choose an option:",
            options=[
                tenant_application_pb2.MenuOption(id="1", label="Check Balance"),
                tenant_application_pb2.MenuOption(id="2", label="Pay $10"),
            ],
            updated_state=state,
        )

    def HandlePaymentConfirmation(self, request, context):
        return tenant_application_pb2.MenuResponse(
            type=tenant_application_pb2.MenuResponse.END,
            message="Payment confirmed.",
        )

    def HandleError(self, request, context):
        return tenant_application_pb2.MenuResponse(
            type=tenant_application_pb2.MenuResponse.END,
            message="An error occurred.",
        )

    def GetTenantConfig(self, request, context):
        return tenant_application_pb2.TenantAppConfig(
            tenant_id=request.tenant_id,
            welcome_message="Welcome to Mock Bank",
        )

    def Health(self, request, context):
        return common_pb2.HealthResponse(
            status=common_pb2.HealthResponse.SERVING,
            version="1.0.0",
        )


def serve():
    port = os.environ.get("PORT", "50053")
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    tenant_application_pb2_grpc.add_TenantUSSDAppServicer_to_server(
        MockTenantUSSDAppServicer(), server
    )
    server.add_insecure_port(f"0.0.0.0:{port}")
    server.start()
    print(f"Mock Tenant App listening on 0.0.0.0:{port}")
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
