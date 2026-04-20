#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="${SCRIPT_DIR}/../deployments/kubernetes/overlays"

if [[ -z "${ENVIRONMENT}" ]]; then
  echo "Usage: $0 <environment>"
  echo "Environments: staging, production"
  exit 1
fi

if [[ "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "production" ]]; then
  echo "Error: environment must be 'staging' or 'production'"
  exit 1
fi

KUSTOMIZE_PATH="${OVERLAY_DIR}/${ENVIRONMENT}"

echo "[DEPLOY] Validating manifests for environment: ${ENVIRONMENT}"
kubectl apply --dry-run=client -k "${KUSTOMIZE_PATH}"

echo "[DEPLOY] Applying manifests for environment: ${ENVIRONMENT}"
kubectl apply -k "${KUSTOMIZE_PATH}"

echo "[DEPLOY] Rollout status check"
NS="$(grep '^namespace:' "${KUSTOMIZE_PATH}/kustomization.yaml" | awk '{print $2}')"
kubectl rollout status deployment/session-reconstructor -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/payment-engine -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/messaging-engine -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/go-orchestrator -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/python-gateway -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/ledger-query-service -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/reconciliation-engine -n "${NS}" --timeout=120s || true
kubectl rollout status deployment/audit-service -n "${NS}" --timeout=120s || true

echo "[DEPLOY] Done"
