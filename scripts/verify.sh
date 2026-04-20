#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export PATH="$HOME/go/bin:$PROJECT_ROOT/.tools/protoc/bin:$PATH"
PYTHON_PKG="openai_ussd_kernel.protos.v1"

echo "=== Verifying Open AI-USSD Kernel Engine Protobuf Stubs ==="

# 1. Proto syntax check
echo "[1/4] Running protoc syntax validation..."
PROTO_FILES=()
while IFS= read -r -d '' file; do
  PROTO_FILES+=("$file")
done < <(find "$PROJECT_ROOT/protos/v1" -name '*.proto' -print0 | sort -z)
protoc --proto_path="$PROJECT_ROOT/protos" --descriptor_set_out=/dev/null "${PROTO_FILES[@]}"
echo "    OK: All .proto files parse successfully"

# 2. Go build verification
echo "[2/4] Verifying Go stub compilation..."
cd "$PROJECT_ROOT/go-orchestrator"
go mod tidy
go build ./...
echo "    OK: Go stubs compile"

# 3. Python import verification
echo "[3/4] Verifying Python stub imports..."
cd "$PROJECT_ROOT/python-gateway/src"
python3 -c "
import sys, os
sys.path.insert(0, os.getcwd())
from ${PYTHON_PKG}.common import common_pb2
from ${PYTHON_PKG}.orchestrator import orchestrator_pb2, orchestrator_pb2_grpc
from ${PYTHON_PKG}.tenant import tenant_pb2, tenant_pb2_grpc
from ${PYTHON_PKG}.payment import payment_pb2, payment_pb2_grpc
from ${PYTHON_PKG}.session import session_pb2, session_pb2_grpc
from ${PYTHON_PKG}.audit import audit_pb2, audit_pb2_grpc
from ${PYTHON_PKG}.messaging import messaging_pb2, messaging_pb2_grpc
from ${PYTHON_PKG}.ledger import ledger_pb2, ledger_pb2_grpc
from ${PYTHON_PKG}.admin import admin_pb2, admin_pb2_grpc
from ${PYTHON_PKG}.reconciliation import reconciliation_pb2, reconciliation_pb2_grpc
from ${PYTHON_PKG}.webhook import webhook_pb2, webhook_pb2_grpc
from ${PYTHON_PKG}.gateway import gateway_pb2, gateway_pb2_grpc
from ${PYTHON_PKG}.ai import ai_pb2, ai_pb2_grpc
from ${PYTHON_PKG}.tenant_application import tenant_application_pb2, tenant_application_pb2_grpc
print('    OK: Python stubs import successfully')
"

# 4. Rust build verification
echo "[4/5] Verifying Rust tonic build..."
if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi
export PROTOC="$PROJECT_ROOT/.tools/protoc/bin/protoc"
cd "$PROJECT_ROOT/rust-engine"
cargo build --workspace
echo "    OK: Rust stubs compile"

# 5. Check generated files exist
echo "[5/5] Checking generated artifacts..."
for domain in common orchestrator tenant payment session audit messaging ledger admin reconciliation webhook gateway ai tenant_application; do
  go_dir="$PROJECT_ROOT/go-orchestrator/internal/gen/$domain"
  if [ ! -d "$go_dir" ]; then
    echo "    MISSING: Go stub directory for $domain"
    exit 1
  fi
  py_dir="$PROJECT_ROOT/python-gateway/src/openai_ussd_kernel/protos/v1/$domain"
  if [ ! -d "$py_dir" ]; then
    echo "    MISSING: Python stub directory for $domain"
    exit 1
  fi
done
echo "    OK: All artifact directories present"

echo ""
echo "=== All Verifications Passed ==="
