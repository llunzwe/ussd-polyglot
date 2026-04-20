#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROTOS_DIR="$PROJECT_ROOT/protos"
OUT_DIR="$PROJECT_ROOT/python-gateway/src/openai_ussd_kernel/protos"

mkdir -p "$OUT_DIR"

PYTHON_CMD="${PYTHON_CMD:-python3}"

# Clean old generated files to avoid stale artifacts
rm -rf "$OUT_DIR/v1"

PROTO_FILES=()
while IFS= read -r -d '' file; do
  PROTO_FILES+=("$file")
done < <(find "$PROTOS_DIR/v1" -name '*.proto' -print0 | sort -z)

$PYTHON_CMD -m grpc_tools.protoc \
  --proto_path="$PROTOS_DIR" \
  --python_out="$OUT_DIR" \
  --grpc_python_out="$OUT_DIR" \
  "${PROTO_FILES[@]}"

# Fix imports so generated files work inside the openai_ussd_kernel.protos package.
# Rewrite "from v1.X import" -> "from openai_ussd_kernel.protos.v1.X import"
# and "import X_pb2 as" -> "from openai_ussd_kernel.protos.v1 import X_pb2 as"
# The latter only applies to flat imports (common_pb2), the former to nested.
while IFS= read -r -d '' f; do
  if [ -f "$f" ]; then
    sed -i 's/from v1\.\([a-zA-Z0-9_]*\) import /from openai_ussd_kernel.protos.v1.\1 import /g' "$f"
    sed -i 's/^import \([a-zA-Z_][a-zA-Z0-9_]*_pb2\) as /from openai_ussd_kernel.protos.v1 import \1 as /g' "$f"
  fi
done < <(find "$OUT_DIR/v1" -name '*_pb2*.py' -print0)

# Ensure __init__.py exists in all generated subdirectories so they are packages
while IFS= read -r -d '' d; do
  if [ ! -f "$d/__init__.py" ]; then
    touch "$d/__init__.py"
  fi
done < <(find "$OUT_DIR/v1" -type d -print0)

echo "Python stubs generated in $OUT_DIR/v1"
