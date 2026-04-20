"""End-to-end USSD flow integration test."""

import uuid

import grpc
import pytest
import requests

from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2
from openai_ussd_kernel.protos.v1.common import common_pb2

from conftest import GATEWAY_URL


SERVICE_CODE = "*123*1#"
TENANT_ENDPOINT = "mock-tenant-app:50053"


def ensure_tenant_registered(orchestrator_stub):
    """Register a test tenant if not already present."""
    tenant_id = str(uuid.uuid4())
    try:
        resp = orchestrator_stub.RegisterTenant(
            orchestrator_pb2.RegisterTenantRequest(
                tenant_id=tenant_id,
                name="Mock Bank",
                service_codes=[SERVICE_CODE],
                endpoint=TENANT_ENDPOINT,
                rate_limit_rps=100,
            ),
            timeout=5,
        )
        return resp.tenant_id
    except grpc.RpcError as e:
        # If already exists, generate a new tenant id and try again
        # In a real scenario we'd query first, but for tests we just retry
        resp = orchestrator_stub.RegisterTenant(
            orchestrator_pb2.RegisterTenantRequest(
                name="Mock Bank",
                service_codes=[SERVICE_CODE],
                endpoint=TENANT_ENDPOINT,
                rate_limit_rps=100,
            ),
            timeout=5,
        )
        return resp.tenant_id


def test_full_ussd_flow(orchestrator_stub, unique_session_id, unique_phone_number):
    """Simulate a complete USSD session: balance check and payment."""
    import grpc

    # Ensure tenant is registered so routing works
    ensure_tenant_registered(orchestrator_stub)

    session_id = unique_session_id
    phone = unique_phone_number

    # Step 1: Initial callback (empty text)
    resp = requests.post(
        f"{GATEWAY_URL}/ussd/callback",
        json={
            "sessionId": session_id,
            "phoneNumber": phone,
            "text": "",
            "serviceCode": SERVICE_CODE,
            "networkCode": "ZW-Econet",
        },
        timeout=10,
    )
    assert resp.status_code == 200
    body = resp.text
    assert body.startswith("CON "), f"Expected CON response, got: {body}"

    # Step 2: Select option "1" (Check Balance)
    resp = requests.post(
        f"{GATEWAY_URL}/ussd/callback",
        json={
            "sessionId": session_id,
            "phoneNumber": phone,
            "text": "1",
            "serviceCode": SERVICE_CODE,
            "networkCode": "ZW-Econet",
        },
        timeout=10,
    )
    assert resp.status_code == 200
    body = resp.text
    assert "balance" in body.lower() or "$100" in body, f"Unexpected balance response: {body}"

    # Step 3: Start a new session for payment flow
    payment_session_id = str(uuid.uuid4())

    # Initial callback for payment session
    resp = requests.post(
        f"{GATEWAY_URL}/ussd/callback",
        json={
            "sessionId": payment_session_id,
            "phoneNumber": phone,
            "text": "",
            "serviceCode": SERVICE_CODE,
            "networkCode": "ZW-Econet",
        },
        timeout=10,
    )
    assert resp.status_code == 200
    assert resp.text.startswith("CON ")

    # Step 4: Select "Pay $10"
    resp = requests.post(
        f"{GATEWAY_URL}/ussd/callback",
        json={
            "sessionId": payment_session_id,
            "phoneNumber": phone,
            "text": "2",
            "serviceCode": SERVICE_CODE,
            "networkCode": "ZW-Econet",
        },
        timeout=10,
    )
    assert resp.status_code == 200
    body = resp.text
    assert (
        "PaymentInitiated" in body or "Processing" in body
    ), f"Expected payment initiated response, got: {body}"

    # Step 5: Query session state via Go Orchestrator gRPC GetSessionState
    state_resp = orchestrator_stub.GetSessionState(
        orchestrator_pb2.GetSessionStateRequest(session_id=payment_session_id),
        timeout=5,
    )
    assert state_resp.session_id == payment_session_id
    # Session state may be empty or contain payment state depending on events
