"""Africa's Talking HMAC-SHA256 signature validator."""
import hmac
import hashlib


class ATSignatureValidator:
    """Validates webhook signatures from Africa's Talking."""

    def __init__(self, api_key: str):
        self.api_key = api_key

    def validate(self, payload: bytes, signature: str) -> bool:
        expected = hmac.new(
            self.api_key.encode(),
            payload,
            hashlib.sha256
        ).hexdigest()
        return hmac.compare_digest(expected, signature)
