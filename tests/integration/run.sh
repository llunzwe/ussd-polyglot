#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.integration.yml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Open AI-USSD Kernel Integration Tests ===${NC}"

# Cleanup function
cleanup() {
    echo -e "${YELLOW}--- Tearing down integration stack ---${NC}"
    docker compose -f "${COMPOSE_FILE}" down -v || true
}
trap cleanup EXIT

# Start stack
echo -e "${YELLOW}--- Starting Docker Compose stack ---${NC}"
docker compose -f "${COMPOSE_FILE}" up --build -d

# Wait for services to be healthy
echo -e "${YELLOW}--- Waiting for services to be healthy ---${NC}"
MAX_WAIT=120
WAITED=0

while true; do
    # Check docker compose ps for healthy status
    UNHEALTHY=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | grep -c '"Health":"unhealthy"' || true)
    HEALTHY=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | grep -c '"Health":"healthy"' || true)
    TOTAL=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | wc -l || echo "0")
    
    # Also curl gateway health as a secondary check
    GATEWAY_OK=false
    if curl -sf http://localhost:8000/health >/dev/null 2>&1; then
        GATEWAY_OK=true
    fi

    ORCH_OK=false
    if curl -sf http://localhost:8080/metrics >/dev/null 2>&1; then
        ORCH_OK=true
    fi

    echo "Healthy containers: ${HEALTHY}/${TOTAL} | Gateway: ${GATEWAY_OK} | Orchestrator metrics: ${ORCH_OK}"

    if [ "${GATEWAY_OK}" = "true" ] && [ "${ORCH_OK}" = "true" ] && [ "${HEALTHY}" -ge 3 ]; then
        echo -e "${GREEN}All critical services are up.${NC}"
        break
    fi

    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo -e "${RED}Timed out waiting for services.${NC}"
        docker compose -f "${COMPOSE_FILE}" logs --tail=50
        exit 1
    fi

    sleep 5
    WAITED=$((WAITED + 5))
done

# Run tests
echo -e "${YELLOW}--- Running pytest integration tests ---${NC}"
EXIT_CODE=0

# Run from project root so Python can find the gateway source/protos
pushd "${PROJECT_ROOT}" >/dev/null
PYTHONPATH="${PROJECT_ROOT}/python-gateway/src:${PROJECT_ROOT}/tests/integration" \
    pytest tests/integration/ -v || EXIT_CODE=$?
popd >/dev/null

# Summary
if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}=== Integration tests passed ===${NC}"
else
    echo -e "${RED}=== Integration tests failed (exit $EXIT_CODE) ===${NC}"
fi

exit "$EXIT_CODE"
