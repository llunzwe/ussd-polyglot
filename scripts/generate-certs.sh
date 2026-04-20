#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../.certs"

echo "[CERTS] Generating self-signed CA and mTLS certificates in ${CERTS_DIR}"

mkdir -p "${CERTS_DIR}"

# Generate CA key and certificate
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "${CERTS_DIR}/ca.key" \
  -out "${CERTS_DIR}/ca.crt" \
  -subj "/C=US/O=OpenAI-USSD-Kernel/CN=ussd-kernel-ca"

SERVICES=("session-reconstructor" "payment-engine" "go-orchestrator" "python-gateway")

for SERVICE in "${SERVICES[@]}"; do
  echo "[CERTS] Generating certificate for ${SERVICE}"

  # Generate service private key and CSR
  openssl req -newkey rsa:4096 -nodes \
    -keyout "${CERTS_DIR}/${SERVICE}.key" \
    -out "${CERTS_DIR}/${SERVICE}.csr" \
    -subj "/C=US/O=OpenAI-USSD-Kernel/CN=${SERVICE}"

  # Sign CSR with CA
  openssl x509 -req -in "${CERTS_DIR}/${SERVICE}.csr" \
    -CA "${CERTS_DIR}/ca.crt" \
    -CAkey "${CERTS_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERTS_DIR}/${SERVICE}.crt" \
    -days 365 -sha256

  # Clean up CSR
  rm -f "${CERTS_DIR}/${SERVICE}.csr"
done

# Clean up CA serial file
rm -f "${CERTS_DIR}/ca.srl"

echo "[CERTS] Done. Files located in ${CERTS_DIR}"
echo "[CERTS] Directory listing:"
ls -la "${CERTS_DIR}"
