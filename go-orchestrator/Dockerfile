# syntax=docker/dockerfile:1

# Builder stage
FROM golang:1.24 AS builder

WORKDIR /workspace

# Copy module files first for caching
COPY go-orchestrator/go.mod go-orchestrator/go.sum ./
RUN go mod download

# Copy source code
COPY go-orchestrator/ .

# Build the orchestrator binary
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/orchestrator ./cmd/orchestrator

# Runtime stage
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /bin/orchestrator /usr/local/bin/orchestrator

EXPOSE 9090 8080

CMD ["orchestrator"]
