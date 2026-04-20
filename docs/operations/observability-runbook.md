# Observability Runbook

## Overview

The Open AI-USSD Kernel Engine uses a unified observability stack across Rust, Go, and Python services:

- **Metrics**: Prometheus (counters, histograms, gauges)
- **Tracing**: OpenTelemetry-style trace propagation via `x-trace-id` gRPC metadata
- **Logging**: Structured JSON logs with consistent fields
- **Dashboards**: Grafana with provisioned Prometheus, Loki, and Tempo datasources

## Structured Logging Standard

All services emit JSON logs with the following base fields:

| Field        | Description                              |
|--------------|------------------------------------------|
| `timestamp`  | ISO-8601 timestamp                       |
| `level`      | Log level (INFO, WARN, ERROR, etc.)      |
| `service`    | Service name (e.g., `python-gateway`)    |
| `trace_id`   | Correlation ID propagated across calls   |
| `span_id`    | OpenTelemetry span identifier (Rust/Go)  |
| `message`    | Human-readable log message               |
| `attributes` | Key/value map of additional context      |

### Service-specific log implementations

- **Rust**: `tracing-subscriber` with `json` feature and `RUST_LOG` env filter.
- **Go**: `slog` with `slog.NewJSONHandler(os.Stdout, nil)`.
- **Python**: Custom `JsonFormatter` on the root `logging` handler.

## Metric Naming Conventions

- Use `snake_case`
- Suffix counters with `_total`
- Suffix histograms with `_duration_seconds` or `_bytes`
- Include descriptive labels (e.g., `status`, `provider`, `tenant_id`)

Example metrics:

```text
forward_ussd_total{status="success"}
append_event_duration_seconds{status="success"}
payment_initiated_total{provider="ecocash",status="success"}
ussd_requests_total{service_code="*123#",status="success"}
```

## Trace Propagation

Every gRPC call carries an `x-trace-id` metadata header:

1. **Python Gateway** generates a UUIDv4 trace ID on incoming HTTP requests and injects it into outgoing gRPC metadata.
2. **Go Orchestrator** extracts `x-trace-id` from incoming metadata, attaches it to `slog` logs, and forwards it to downstream Rust services.
3. **Rust Engines** extract `x-trace-id` via `ussd_kernel_common::telemetry::extract_trace_context()` and create a `tracing` span.

## Query Examples

### Loki (LogQL)

```logql
# Find all errors for a specific trace
{service="go-orchestrator"} | json | trace_id="abc-123" | level="ERROR"

# Count USSD callbacks by status
{service="python-gateway"} | json | line_format "{{.attributes}}"
```

### Prometheus (PromQL)

```promql
# Requests per second by service
rate(forward_ussd_total[1m])

# P99 latency for AppendEvent
histogram_quantile(0.99, rate(append_event_duration_seconds_bucket[5m]))

# Error rate %
(
  sum(rate(forward_ussd_total{status="error"}[5m]))
  /
  sum(rate(forward_ussd_total[5m]))
) * 100

# Active sessions (if exposed as gauge)
session_active_sessions
```

## Alerting Rules (Prometheus)

High-level alert thresholds:

| Alert                  | Condition                                      |
|------------------------|------------------------------------------------|
| HighErrorRate          | `rate(forward_ussd_total{status="error"}[5m]) > 0.1` |
| HighLatency            | `histogram_quantile(0.99, rate(append_event_duration_seconds_bucket[5m])) > 2` |
| LowPaymentSuccessRate  | `rate(payment_initiated_total{status="success"}[5m]) / rate(payment_initiated_total[5m]) < 0.95` |
| RateLimitHitsSpike     | `rate(rate_limit_hits_total[5m]) > 10`         |

## Running the Observability Stack

```bash
docker compose -f observability/docker-compose.observability.yml up -d
```

Access points:
- Grafana: http://localhost:3000 (admin / admin)
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093
- Loki: http://localhost:3100
- Tempo: http://localhost:3200

## Troubleshooting

- **Missing Rust metrics**: Rust services currently emit metrics as structured log events (`metric_name`, `metric_value`, `metric_labels`). A Prometheus exporter can be added later.
- **Trace gaps**: Ensure all gRPC clients inject `x-trace-id` and all servers extract it.
- **High cardinality**: Avoid unbounded label values (e.g., raw `session_id`) in Prometheus metrics.
