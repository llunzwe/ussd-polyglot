"""Rate limiting integration test."""

import concurrent.futures
import time
import uuid

import pytest
import requests

from conftest import GATEWAY_URL


SERVICE_CODE = "*123*1#"


def test_rate_limiting():
    """Hammer the gateway with 20 requests and assert some are rate limited."""
    session_id = str(uuid.uuid4())
    phone = f"26371{uuid.uuid4().int % 10000000:07d}"

    payloads = []
    for i in range(20):
        payloads.append(
            {
                "sessionId": session_id,
                "phoneNumber": phone,
                "text": "",
                "serviceCode": SERVICE_CODE,
                "networkCode": "ZW-Econet",
            }
        )

    responses = []

    def send_request(payload):
        try:
            resp = requests.post(
                f"{GATEWAY_URL}/ussd/callback",
                json=payload,
                timeout=5,
            )
            return resp.status_code, resp.text
        except Exception as e:
            return None, str(e)

    # Fire all requests as quickly as possible
    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as executor:
        futures = [executor.submit(send_request, p) for p in payloads]
        for future in concurrent.futures.as_completed(futures):
            responses.append(future.result())
    elapsed = time.time() - start

    assert elapsed < 2.0, "Requests took too long to fire"

    successful = [r for r in responses if r[0] == 200]
    rate_limited = [
        r for r in responses
        if r[0] == 200 and ("too many requests" in r[1].lower() or "END " in r[1])
    ]

    # We expect at least some rate-limited or error responses due to burst
    # The gateway uses an in-memory token bucket with 10 tokens per minute
    # so the first ~10 should succeed and the rest should be rate limited.
    limited_count = sum(
        1 for _, text in responses
        if "too many requests" in text.lower() or "too many" in text.lower()
    )

    assert limited_count > 0, (
        f"Expected some rate-limited responses, got: {responses}"
    )
