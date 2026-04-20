"""Tests for OrchestratorClient."""

import grpc
import pytest
from unittest.mock import MagicMock, patch

from openai_ussd_kernel.clients.exceptions import OrchestratorError, RateLimitError, SessionTimeoutError
from openai_ussd_kernel.clients.orchestrator import OrchestratorClient


@pytest.fixture(autouse=True)
def reset_singleton():
    OrchestratorClient.reset_instance()
    yield
    OrchestratorClient.reset_instance()


def test_singleton_behavior():
    c1 = OrchestratorClient()
    c2 = OrchestratorClient()
    assert c1 is c2


@patch("openai_ussd_kernel.clients.orchestrator.grpc.insecure_channel")
def test_forward_ussd_success(mock_channel):
    mock_stub = MagicMock()
    mock_response = MagicMock()
    mock_stub.ForwardUSSD.return_value = mock_response

    with patch("openai_ussd_kernel.clients.orchestrator.orchestrator_pb2_grpc.OrchestratorStub", return_value=mock_stub):
        client = OrchestratorClient()
        client._stub = mock_stub
        resp = client.forward_ussd(
            session_id="s1",
            phone_number="+263771000001",
            text="1",
            service_code="*123#",
            network_code="ZW",
        )
    assert resp is mock_response
    mock_stub.ForwardUSSD.assert_called_once()


@patch("openai_ussd_kernel.clients.orchestrator.grpc.insecure_channel")
def test_forward_ussd_orchestrator_error(mock_channel):
    mock_stub = MagicMock()
    exc = grpc.RpcError()
    exc.code = lambda: grpc.StatusCode.UNAVAILABLE
    exc.details = lambda: "service unavailable"
    mock_stub.ForwardUSSD.side_effect = exc

    with patch("openai_ussd_kernel.clients.orchestrator.orchestrator_pb2_grpc.OrchestratorStub", return_value=mock_stub):
        client = OrchestratorClient()
        client._stub = mock_stub
        with pytest.raises(OrchestratorError):
            client.forward_ussd(
                session_id="s1",
                phone_number="+263771000001",
                text="1",
                service_code="*123#",
                network_code="ZW",
            )


@patch("openai_ussd_kernel.clients.orchestrator.grpc.insecure_channel")
def test_forward_ussd_rate_limit(mock_channel):
    mock_stub = MagicMock()
    exc = grpc.RpcError()
    exc.code = lambda: grpc.StatusCode.RESOURCE_EXHAUSTED
    exc.details = lambda: "rate limited"
    mock_stub.ForwardUSSD.side_effect = exc

    with patch("openai_ussd_kernel.clients.orchestrator.orchestrator_pb2_grpc.OrchestratorStub", return_value=mock_stub):
        client = OrchestratorClient()
        client._stub = mock_stub
        with pytest.raises(RateLimitError):
            client.forward_ussd(
                session_id="s1",
                phone_number="+263771000001",
                text="1",
                service_code="*123#",
                network_code="ZW",
            )


@patch("openai_ussd_kernel.clients.orchestrator.grpc.insecure_channel")
def test_forward_ussd_timeout(mock_channel):
    mock_stub = MagicMock()
    exc = grpc.RpcError()
    exc.code = lambda: grpc.StatusCode.DEADLINE_EXCEEDED
    exc.details = lambda: "timeout"
    mock_stub.ForwardUSSD.side_effect = exc

    with patch("openai_ussd_kernel.clients.orchestrator.orchestrator_pb2_grpc.OrchestratorStub", return_value=mock_stub):
        client = OrchestratorClient()
        client._stub = mock_stub
        with pytest.raises(SessionTimeoutError):
            client.forward_ussd(
                session_id="s1",
                phone_number="+263771000001",
                text="1",
                service_code="*123#",
                network_code="ZW",
            )


@patch("openai_ussd_kernel.clients.orchestrator.grpc.insecure_channel")
def test_health_success(mock_channel):
    mock_stub = MagicMock()
    mock_response = MagicMock()
    mock_stub.Health.return_value = mock_response

    with patch("openai_ussd_kernel.clients.orchestrator.orchestrator_pb2_grpc.OrchestratorStub", return_value=mock_stub):
        client = OrchestratorClient()
        client._stub = mock_stub
        resp = client.health()
    assert resp is mock_response
