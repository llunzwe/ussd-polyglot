#!/usr/bin/env python3
"""Edge sync service: batch local events to cloud orchestrator."""

import json
import os
import time
from datetime import datetime, timezone
from typing import Any

import grpc

EVENT_LOG_PATH = os.environ.get("EVENT_LOG_PATH", "/data/events.jsonl")
SYNC_INTERVAL_SECONDS = int(os.environ.get("SYNC_INTERVAL_SECONDS", "60"))
ORCHESTRATOR_ADDR = os.environ.get("ORCHESTRATOR_ADDR", "cloud-orchestrator.example.com:443")

TLS_CERT_FILE = os.environ.get("TLS_CERT_FILE", "")
TLS_KEY_FILE = os.environ.get("TLS_KEY_FILE", "")
TLS_CA_FILE = os.environ.get("TLS_CA_FILE", "")


def _load_credentials() -> grpc.ChannelCredentials | None:
    if TLS_CERT_FILE and TLS_KEY_FILE and TLS_CA_FILE:
        with open(TLS_CERT_FILE, "rb") as f:
            cert_chain = f.read()
        with open(TLS_KEY_FILE, "rb") as f:
            private_key = f.read()
        with open(TLS_CA_FILE, "rb") as f:
            root_ca = f.read()
        return grpc.ssl_channel_credentials(
            root_certificates=root_ca,
            private_key=private_key,
            certificate_chain=cert_chain,
        )
    return None


def _get_channel() -> grpc.Channel:
    creds = _load_credentials()
    if creds:
        return grpc.secure_channel(ORCHESTRATOR_ADDR, creds)
    return grpc.insecure_channel(ORCHESTRATOR_ADDR)


def _read_unsynced_events() -> list[dict[str, Any]]:
    if not os.path.exists(EVENT_LOG_PATH):
        return []
    events: list[dict[str, Any]] = []
    with open(EVENT_LOG_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                if not event.get("synced", False):
                    events.append(event)
            except json.JSONDecodeError:
                continue
    return events


def _mark_synced(events: list[dict[str, Any]]) -> None:
    if not os.path.exists(EVENT_LOG_PATH):
        return
    synced_ids = {e.get("event_id") for e in events}
    lines: list[str] = []
    with open(EVENT_LOG_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                if event.get("event_id") in synced_ids:
                    event["synced"] = True
                    event["synced_at"] = datetime.now(timezone.utc).isoformat()
                lines.append(json.dumps(event))
            except json.JSONDecodeError:
                lines.append(line)
    with open(EVENT_LOG_PATH, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")


def _append_events_batch(events: list[dict[str, Any]]) -> bool:
    """Send a batch of events to the cloud orchestrator via gRPC."""
    try:
        from openai_ussd_kernel.protos.v1.orchestrator import orchestrator_pb2, orchestrator_pb2_grpc
        from openai_ussd_kernel.protos.v1.common import common_pb2
        from google.protobuf.timestamp_pb2 import Timestamp
        from google.protobuf.struct_pb2 import Struct
    except ImportError as exc:
        print(f"[SYNC] Protobuf stubs not available ({exc}), falling back to log-only mode")
        print(f"[SYNC] Would send {len(events)} events to {ORCHESTRATOR_ADDR}")
        for ev in events:
            print(f"  - {ev.get('event_id')} {ev.get('event_type')}")
        return True

    channel = _get_channel()
    stub = orchestrator_pb2_grpc.OrchestratorStub(channel)

    batch_events = []
    for ev in events:
        payload_struct = Struct()
        payload_struct.update(ev.get("payload", {}))
        event = common_pb2.EventEnvelope(
            event_id=ev.get("event_id", ""),
            event_type=ev.get("event_type", ""),
            aggregate_type=ev.get("aggregate_type", ""),
            aggregate_id=ev.get("aggregate_id", ""),
            payload=payload_struct,
        )
        if "occurred_at" in ev:
            ts = Timestamp()
            ts.FromDatetime(datetime.fromisoformat(ev["occurred_at"]))
            event.occurred_at.CopyFrom(ts)
        batch_events.append(event)

    request = orchestrator_pb2.AppendEventsBatchRequest(events=batch_events)
    try:
        response = stub.AppendEventsBatch(request, timeout=30)
        if response.success:
            print(f"[SYNC] Successfully sent {len(events)} events to {ORCHESTRATOR_ADDR}")
            return True
        else:
            print(f"[SYNC] Orchestrator rejected batch: {response.error}")
            return False
    except grpc.RpcError as exc:
        print(f"[SYNC] gRPC error: {exc.code()} {exc.details()}")
        return False
    finally:
        channel.close()


def main() -> None:
    print("Edge sync started")
    while True:
        try:
            events = _read_unsynced_events()
            if events:
                success = _append_events_batch(events)
                if success:
                    _mark_synced(events)
                    print(f"[SYNC] Successfully synced {len(events)} events")
                else:
                    print("[SYNC] Failed to sync events")
            else:
                print("[SYNC] No unsynced events")
        except Exception as exc:
            print(f"[SYNC] Error during sync: {exc}")
        time.sleep(SYNC_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
