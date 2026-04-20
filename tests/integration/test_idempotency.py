"""Idempotency integration test."""

import uuid

import grpc
import pytest

from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2
from openai_ussd_kernel.protos.v1.common import common_pb2


def test_idempotency_duplicate_key(orchestrator_stub):
    """Send same idempotency_key twice to AppendEvent; second should fail as duplicate."""
    aggregate_id = str(uuid.uuid4())
    idempotency_key = f"test-idem-{uuid.uuid4()}"

    # First append should succeed
    resp1 = orchestrator_stub.AppendEvent(
        orchestrator_pb2.AppendEventRequest(
            event_type="TestEvent",
            aggregate_type="TestAggregate",
            aggregate_id=aggregate_id,
            idempotency_key=common_pb2.IdempotencyKey(value=idempotency_key),
        ),
        timeout=5,
    )
    assert resp1.version > 0

    # Second append with same key should return AlreadyExists
    with pytest.raises(grpc.RpcError) as exc_info:
        orchestrator_stub.AppendEvent(
            orchestrator_pb2.AppendEventRequest(
                event_type="TestEvent",
                aggregate_type="TestAggregate",
                aggregate_id=aggregate_id,
                idempotency_key=common_pb2.IdempotencyKey(value=idempotency_key),
            ),
            timeout=5,
        )
    assert exc_info.value.code() == grpc.StatusCode.ALREADY_EXISTS
