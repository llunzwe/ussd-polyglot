use std::net::SocketAddr;
use std::time::Instant;

use lazy_static::lazy_static;
use prometheus::{CounterVec, HistogramVec, Registry, Encoder, TextEncoder, gather};
use tokio::task::JoinHandle;
use tracing::{error, info};

lazy_static! {
    pub static ref REGISTRY: Registry = Registry::new();
    pub static ref GRPC_REQUESTS_TOTAL: CounterVec = CounterVec::new(
        prometheus::Opts::new("ussd_grpc_requests_total", "Total gRPC requests"),
        &["service", "method", "status"]
    ).unwrap();
    pub static ref GRPC_REQUEST_DURATION: HistogramVec = HistogramVec::new(
        prometheus::HistogramOpts::new("ussd_grpc_request_duration_seconds", "gRPC request duration")
            .buckets(prometheus::DEFAULT_BUCKETS.to_vec()),
        &["service", "method"]
    ).unwrap();
    pub static ref DB_QUERY_DURATION: HistogramVec = HistogramVec::new(
        prometheus::HistogramOpts::new("ussd_db_query_duration_seconds", "Database query duration")
            .buckets(prometheus::DEFAULT_BUCKETS.to_vec()),
        &["operation", "table"]
    ).unwrap();
}

pub fn register_metrics() {
    REGISTRY.register(Box::new(GRPC_REQUESTS_TOTAL.clone())).unwrap_or_default();
    REGISTRY.register(Box::new(GRPC_REQUEST_DURATION.clone())).unwrap_or_default();
    REGISTRY.register(Box::new(DB_QUERY_DURATION.clone())).unwrap_or_default();
}

pub fn record_grpc_request(service: &str, method: &str, status: &str, duration_secs: f64) {
    GRPC_REQUESTS_TOTAL.with_label_values(&[service, method, status]).inc();
    GRPC_REQUEST_DURATION.with_label_values(&[service, method]).observe(duration_secs);
}

pub fn record_db_query(operation: &str, table: &str, duration_secs: f64) {
    DB_QUERY_DURATION.with_label_values(&[operation, table]).observe(duration_secs);
}

pub fn start_metrics_server(port: u16) -> JoinHandle<()> {
    tokio::spawn(async move {
        let addr: SocketAddr = match format!("0.0.0.0:{}", port).parse() {
            Ok(a) => a,
            Err(e) => {
                error!("Invalid metrics bind address: {}", e);
                return;
            }
        };
        let listener = match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => l,
            Err(e) => {
                error!("Failed to bind metrics server: {}", e);
                return;
            }
        };
        info!("Metrics server listening on {}", addr);
        loop {
            let (mut socket, _) = match listener.accept().await {
                Ok(s) => s,
                Err(e) => {
                    error!("Metrics accept error: {}", e);
                    continue;
                }
            };
            let encoder = TextEncoder::new();
            let metric_families = gather();
            let mut buffer = vec![];
            if encoder.encode(&metric_families, &mut buffer).is_err() {
                continue;
            }
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\r\n{}",
                buffer.len(),
                String::from_utf8_lossy(&buffer)
            );
            let _ = tokio::io::AsyncWriteExt::write_all(&mut socket, response.as_bytes()).await;
        }
    })
}

/// Helper to instrument an async gRPC handler.
#[macro_export]
macro_rules! instrument_grpc {
    ($service:expr, $method:expr, $block:expr) => {{
        let start = Instant::now();
        let result = $block.await;
        let status = if result.is_ok() { "ok" } else { "error" };
        $crate::metrics::record_grpc_request($service, $method, status, start.elapsed().as_secs_f64());
        result
    }};
}
