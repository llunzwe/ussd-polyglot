"""Session integrity / hash chain integration test."""

import uuid

import grpc
import pytest

from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2
from openai_ussd_kernel.protos.v1.common import common_pb2
from openai_ussd_kernel.protos.v1.session import session_pb2


def test_session_integrity_hash_chain(session_stub, orchestrator_stub):
    """Use Rust Session Reconstructor directly to verify integrity for a session."""
    session_id = str(uuid.uuid4())
    tenant_id = str(uuid.uuid4())

    # Seed some events via the orchestrator so the session has history
    for i in range(3):
        orchestrator_stub.AppendEvent(
            orchestrator_pb2.AppendEventRequest(
                event_type="SessionEvent",
                aggregate_type="Session",
                aggregate_id=session_id,
                context=common_pb2.SessionContext(
                    session_id=session_id,
                    tenant_id=tenant_id,
                ),
                payload={"step": str(i)},
            ),
            timeout=5,
        )

    # Reconstruct the session and verify it returns a valid hash
    recon_resp = session_stub.ReconstructSession(
        session_pb2.ReconstructSessionRequest(
            session_id=session_id,
            tenant_id=tenant_id,
            max_events=100,
            include_merkle_proof=True,
        ),
        timeout=5,
    )
    assert recon_resp.session_id == session_id
    assert recon_resp.is_valid is True
    assert recon_resp.events_replayed >= 3
    assert recon_resp.integrity_hash != ""

    # Verify session integrity explicitly
    verify_resp = session_stub.VerifySessionIntegrity(
        session_pb2.VerifySessionRequest(
            session_id=session_id,
            expected_hash=recon_resp.integrity_hash,
            tracing=session_pb2.TracingContext(
                trace_id="test-trace",
                span_id="test-span",
                baggage={"tenant_id": tenant_id},
            ),
        ),
        timeout=5,
    )
    assert verify_resp.is_valid is True
    assert verify_resp.computed_hash == recon_resp.integrity_hash
