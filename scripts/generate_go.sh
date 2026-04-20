#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Ensure Go plugins are available
export PATH="$PATH:$HOME/go/bin"
if ! command -v protoc-gen-go &> /dev/null; then
    echo "Installing protoc-gen-go..."
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
fi

if ! command -v protoc-gen-go-grpc &> /dev/null; then
    echo "Installing protoc-gen-go-grpc..."
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
fi

PROTOS_DIR="$PROJECT_ROOT/protos"
OUT_DIR="$PROJECT_ROOT/go-orchestrator"
PROTOC="$PROJECT_ROOT/.tools/protoc/bin/protoc"

rm -rf "$PROJECT_ROOT/go-orchestrator/internal/gen"
mkdir -p "$PROJECT_ROOT/go-orchestrator/internal/gen"

PROTO_FILES=()
while IFS= read -r -d '' file; do
  PROTO_FILES+=("$file")
done < <(find "$PROTOS_DIR/v1" -name '*.proto' -print0 | sort -z)

"$PROTOC" \
  --proto_path="$PROTOS_DIR" \
  --go_out="$OUT_DIR" \
  --go_opt=module=github.com/openai-ussd-kernel/go-orchestrator \
  --go-grpc_out="$OUT_DIR" \
  --go-grpc_opt=module=github.com/openai-ussd-kernel/go-orchestrator \
  "${PROTO_FILES[@]}"

echo "Go stubs generated in $OUT_DIR/internal/gen"
