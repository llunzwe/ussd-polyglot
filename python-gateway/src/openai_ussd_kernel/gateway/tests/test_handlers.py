"""Tests for USSD gateway handlers."""

import pytest
from unittest.mock import MagicMock, patch

from openai_ussd_kernel.gateway.handlers import ussd_callback, _rate_limiter, _session_tracker
from openai_ussd_kernel.gateway.models import UssdRequest
from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2


@pytest.fixture(autouse=True)
def reset_state():
    _rate_limiter.clear("+263771000001")
    _session_tracker.clear("sess-001")
    yield
    _rate_limiter.clear("+263771000001")
    _session_tracker.clear("sess-001")


@patch("openai_ussd_kernel.gateway.handlers._orchestrator")
def test_ussd_callback_success_con(mock_orchestrator):
    grpc_resp = orchestrator_pb2.ForwardUSSDResponse()
    grpc_resp.type = 0  # CON
    grpc_resp.menu_text = "Welcome"
    opt = grpc_resp.options.add()
    opt.id = "1"
    opt.label = "Balance"
    mock_orchestrator.forward_ussd.return_value = grpc_resp

    req = UssdRequest(
        sessionId="sess-001",
        phoneNumber="+263771000001",
        text="",
        serviceCode="*123#",
        networkCode="ZW-Econet",
    )
    result = ussd_callback(req)
    assert result.startswith("CON ")
    assert "Welcome" in result
    assert "1. Balance" in result


@patch("openai_ussd_kernel.gateway.handlers._orchestrator")
def test_ussd_callback_success_end(mock_orchestrator):
    grpc_resp = orchestrator_pb2.ForwardUSSDResponse()
    grpc_resp.type = 1  # END
    grpc_resp.menu_text = "Goodbye"
    mock_orchestrator.forward_ussd.return_value = grpc_resp

    req = UssdRequest(
        sessionId="sess-001",
        phoneNumber="+263771000001",
        text="1",
        serviceCode="*123#",
    )
    result = ussd_callback(req)
    assert result == "END Goodbye"


@patch("openai_ussd_kernel.gateway.handlers._orchestrator")
def test_ussd_callback_orchestrator_error(mock_orchestrator):
    from openai_ussd_kernel.clients.exceptions import OrchestratorError
    mock_orchestrator.forward_ussd.side_effect = OrchestratorError("boom")

    req = UssdRequest(
        sessionId="sess-001",
        phoneNumber="+263771000001",
        text="",
        serviceCode="*123#",
    )
    result = ussd_callback(req)
    assert result == "END An error occurred. Please try again."


def test_ussd_callback_missing_fields():
    req = UssdRequest(
        sessionId="",
        phoneNumber="",
        text="",
        serviceCode="",
    )
    result = ussd_callback(req)
    assert result.startswith("END Invalid request")


def test_ussd_callback_rate_limit():
    # Exhaust the bucket quickly
    req = UssdRequest(
        sessionId="sess-001",
        phoneNumber="+263771000001",
        text="",
        serviceCode="*123#",
    )
    # First call uses one token
    with patch("openai_ussd_kernel.gateway.handlers._orchestrator") as mock_orchestrator:
        grpc_resp = orchestrator_pb2.ForwardUSSDResponse()
        grpc_resp.type = 1
        grpc_resp.menu_text = "Ok"
        mock_orchestrator.forward_ussd.return_value = grpc_resp
        ussd_callback(req)

    # Deplete tokens by many rapid calls
    for _ in range(20):
        with patch("openai_ussd_kernel.gateway.handlers._orchestrator") as mock_orchestrator:
            grpc_resp = orchestrator_pb2.ForwardUSSDResponse()
            grpc_resp.type = 1
            grpc_resp.menu_text = "Ok"
            mock_orchestrator.forward_ussd.return_value = grpc_resp
            ussd_callback(req)

    result = ussd_callback(req)
    assert "too many requests" in result
