use std::env;

use anyhow::Context;
use sqlx::postgres::PgPoolOptions;
use tracing::info;
use ussd_kernel_common::v1::session::session_reconstructor_server::SessionReconstructorServer;

use session_reconstructor::application::reconstruct::ReconstructSessionHandler;
use session_reconstructor::infrastructure::cache::SessionCache;
use session_reconstructor::infrastructure::postgres::PgEventStore;
use session_reconstructor::ports::grpc::SessionGrpcServer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    let db_url = env::var("DATABASE_URL").context("DATABASE_URL must be set")?;

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&db_url)
        .await
        .context("failed to connect to postgres")?;

    let store = PgEventStore::new(pool);
    let cache = SessionCache::new();
    let handler = ReconstructSessionHandler::new(store, cache);
    let server = SessionGrpcServer::new(handler);

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr = format!("{}:50051", bind_addr).parse()?;
    info!(addr = %addr, "SessionReconstructor starting");
    ussd_kernel_common::metrics::register_metrics();
    let metrics_port = env::var("METRICS_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(9090u16);
    ussd_kernel_common::metrics::start_metrics_server(metrics_port);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    if tls_enabled {
        info!("TLS enabled for SessionReconstructor");
        let tls_config = ussd_kernel_common::tls::load_server_tls_config(
            &cert_path,
            &key_path,
            &ca_path,
        )
        .map_err(|e| anyhow::anyhow!("failed to load TLS config: {}", e))?;

        tonic::transport::Server::builder()
            .tls_config(tls_config)?
            .add_service(SessionReconstructorServer::new(server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await
            .context("server error")?;
    } else {
        tonic::transport::Server::builder()
            .add_service(SessionReconstructorServer::new(server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await
            .context("server error")?;
    }

    info!("SessionReconstructor shutdown complete");
    Ok(())
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("failed to install ctrl+c handler");
    info!("shutdown signal received, starting graceful shutdown");
}
