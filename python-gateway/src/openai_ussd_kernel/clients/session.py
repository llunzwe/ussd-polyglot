"""Session client stub for interacting with session services."""

from openai_ussd_kernel.clients.orchestrator import OrchestratorClient


class SessionClient:
    """Client for session-related operations, primarily routed via the Go Orchestrator."""

    def __init__(self, orchestrator: OrchestratorClient | None = None):
        self._orchestrator = orchestrator or OrchestratorClient()

    def get_session_state(self, session_id: str) -> dict:
        """Fetch session state via the orchestrator."""
        # This is a stub; in production this would call GetSessionState on the orchestrator
        return {"session_id": session_id, "state": {}}

    def create_session(self, session_id: str, phone_number: str) -> dict:
        """Create a new session via the orchestrator."""
        return {"session_id": session_id, "phone_number": phone_number, "created": True}

    def end_session(self, session_id: str) -> dict:
        """End an existing session via the orchestrator."""
        return {"session_id": session_id, "ended": True}
