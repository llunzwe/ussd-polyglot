"""TLS utilities for gRPC channels."""

import os
from typing import Any

import grpc


def load_channel_credentials(
    cert_file: str, key_file: str, ca_file: str
) -> grpc.ChannelCredentials:
    """Load mutual TLS credentials from PEM files."""
    with open(cert_file, "rb") as f:
        cert_chain = f.read()
    with open(key_file, "rb") as f:
        private_key = f.read()
    with open(ca_file, "rb") as f:
        root_ca = f.read()

    return grpc.ssl_channel_credentials(
        root_certificates=root_ca,
        private_key=private_key,
        certificate_chain=cert_chain,
    )


def get_secure_channel(
    target: str, credentials: grpc.ChannelCredentials, **options: Any
) -> grpc.Channel:
    """Return a secure gRPC channel with the provided credentials and options."""
    channel_options = [
        ("grpc.keepalive_time_ms", options.pop("keepalive_time_ms", 10000)),
        ("grpc.keepalive_timeout_ms", options.pop("keepalive_timeout_ms", 5000)),
        ("grpc.http2.max_pings_without_data", options.pop("max_pings_without_data", 0)),
        ("grpc.http2.min_time_between_pings_ms", options.pop("min_time_between_pings_ms", 10000)),
    ]
    for k, v in options.items():
        channel_options.append((k, v))
    return grpc.secure_channel(target, credentials, options=channel_options)


def get_tls_credentials_from_env() -> grpc.ChannelCredentials | None:
    """Load mTLS credentials from environment variables if all are set."""
    cert_file = os.environ.get("TLS_CERT_FILE", "")
    key_file = os.environ.get("TLS_KEY_FILE", "")
    ca_file = os.environ.get("TLS_CA_FILE", "")

    if cert_file and key_file and ca_file:
        return load_channel_credentials(cert_file, key_file, ca_file)
    return None
