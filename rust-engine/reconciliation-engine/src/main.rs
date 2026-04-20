use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tonic::transport::Server;
use tracing::{error, info};

use ussd_kernel_common::v1::reconciliation::reconciliation_service_server::ReconciliationServiceServer;

use reconciliation_engine::application::handler::ReconciliationHandler;
use reconciliation_engine::infrastructure::postgres_recon_store::PostgresReconStore;
use reconciliation_engine::infrastructure::postgres_transaction_source::PostgresTransactionSource;
use reconciliation_engine::infrastructure::provider_statement_adapter::ProviderStatementAdapter;
use reconciliation_engine::ports::grpc::ReconciliationGrpcServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    info!("Starting reconciliation-engine service");
    ussd_kernel_common::metrics::register_metrics();
    let metrics_port = env::var("METRICS_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(9090u16);
    ussd_kernel_common::metrics::start_metrics_server(metrics_port);

    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        error!("DATABASE_URL environment variable is required");
        std::process::exit(1);
    });

    let grpc_port = env::var("GRPC_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(50058u16);

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    info!("Database pool initialized");

    let transaction_source = Arc::new(PostgresTransactionSource::new(pool.clone()));
    let external_statement = Arc::new(ProviderStatementAdapter::new());
    let store = Arc::new(PostgresReconStore::new(pool.clone()));

    let handler = ReconciliationHandler::new(transaction_source, external_statement, store);

    let grpc_server = ReconciliationGrpcServer { handler };

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr: SocketAddr = format!("{}:{}", bind_addr, grpc_port).parse()?;
    info!("gRPC server listening on {}", addr);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    if tls_enabled {
        info!("TLS enabled for reconciliation-engine");
        let tls_config = ussd_kernel_common::tls::load_server_tls_config(
            &cert_path,
            &key_path,
            &ca_path,
        )?;

        Server::builder()
            .tls_config(tls_config)?
            .add_service(ReconciliationServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    } else {
        Server::builder()
            .add_service(ReconciliationServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    }

    info!("Reconciliation-engine service shutdown complete");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install signal handler")
            .recv()
            .await;
    };

    tokio::select! {
        _ = ctrl_c => info!("Received SIGINT, starting graceful shutdown"),
        _ = terminate => info!("Received SIGTERM, starting graceful shutdown"),
    }
}
