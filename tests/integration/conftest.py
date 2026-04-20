"""Shared fixtures for integration tests."""

import os
import uuid

import pytest
import requests

import grpc

from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2, orchestrator_pb2_grpc
from openai_ussd_kernel.protos.v1.session import session_pb2, session_pb2_grpc
from openai_ussd_kernel.protos.v1.payment import payment_pb2, payment_pb2_grpc


# Service URLs
GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:8000")
ORCHESTRATOR_GRPC_ADDR = os.environ.get("ORCHESTRATOR_GRPC_ADDR", "localhost:9090")
SESSION_GRPC_ADDR = os.environ.get("SESSION_GRPC_ADDR", "localhost:50051")
PAYMENT_GRPC_ADDR = os.environ.get("PAYMENT_GRPC_ADDR", "localhost:50052")


@pytest.fixture(scope="session")
def orchestrator_stub():
    """Yield a gRPC stub for the Go Orchestrator."""
    channel = grpc.insecure_channel(ORCHESTRATOR_GRPC_ADDR)
    stub = orchestrator_pb2_grpc.OrchestratorStub(channel)
    yield stub
    channel.close()


@pytest.fixture(scope="session")
def session_stub():
    """Yield a gRPC stub for the Rust Session Reconstructor."""
    channel = grpc.insecure_channel(SESSION_GRPC_ADDR)
    stub = session_pb2_grpc.SessionReconstructorStub(channel)
    yield stub
    channel.close()


@pytest.fixture(scope="session")
def payment_stub():
    """Yield a gRPC stub for the Rust Payment Engine."""
    channel = grpc.insecure_channel(PAYMENT_GRPC_ADDR)
    stub = payment_pb2_grpc.PaymentEngineStub(channel)
    yield stub
    channel.close()


@pytest.fixture(scope="function")
def unique_session_id():
    """Generate a unique session ID."""
    return str(uuid.uuid4())


@pytest.fixture(scope="function")
def unique_phone_number():
    """Generate a unique phone number."""
    return f"26371{uuid.uuid4().int % 10000000:07d}"
