use tracing::{info, info_span, Span};

/// Initialize `tracing_subscriber` with JSON formatting and env filter.
pub fn init_tracing(service_name: &str) {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "info".into());

    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .json()
        .with_current_span(true)
        .with_target(true)
        .init();

    info!(service = %service_name, "tracing initialized");
}

/// Stub that logs structured metric events.
pub fn record_metric(name: &str, value: f64, labels: &[(&str, &str)]) {
    let labels_str = labels
        .iter()
        .map(|(k, v)| format!("{}={}", k, v))
        .collect::<Vec<_>>()
        .join(",");

    info!(
        metric_name = %name,
        metric_value = %value,
        metric_labels = %labels_str,
        "metric"
    );
}

/// Extract `x-trace-id` from gRPC metadata and create a child span.
pub fn extract_trace_context(md: &tonic::metadata::MetadataMap) -> Option<Span> {
    let trace_id = md
        .get("x-trace-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if trace_id.is_empty() {
        None
    } else {
        Some(info_span!("grpc_request", trace_id = %trace_id))
    }
}
