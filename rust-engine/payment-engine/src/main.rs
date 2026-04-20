use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tonic::transport::Server;
use tracing::{error, info};

use ussd_kernel_common::v1::payment::payment_engine_server::PaymentEngineServer;

use payment_engine::application::callback::ProcessCallbackHandler;
use payment_engine::application::initiate::InitiatePaymentHandler;
use payment_engine::infrastructure::outbox::OutboxRepository;
use payment_engine::infrastructure::postgres::PgPaymentRepository;
use payment_engine::infrastructure::providers::ecocash::EcoCashClient;
use payment_engine::infrastructure::vault::get_vault_client;
use payment_engine::ports::grpc::PaymentGrpcServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    info!("Starting payment-engine service");
    ussd_kernel_common::metrics::register_metrics();
    let metrics_port = env::var("METRICS_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(9090u16);
    ussd_kernel_common::metrics::start_metrics_server(metrics_port);

    // Load config
    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        error!("DATABASE_URL environment variable is required");
        std::process::exit(1);
    });

    let grpc_port = env::var("GRPC_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(50052u16);

    // Initialize DB pool
    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    info!("Database pool initialized");

    // Initialize repositories
    let payment_repo = PgPaymentRepository::new(pool.clone());
    let outbox_repo = OutboxRepository::new(pool.clone());

    // Initialize vault and provider clients
    let vault = get_vault_client().await?;
    let ecocash_creds = vault.get_credentials("ecocash").await.map_err(|e| {
        error!("Failed to load EcoCash credentials: {}", e);
        std::io::Error::new(std::io::ErrorKind::Other, e)
    })?;

    let ecocash_client = Arc::new(EcoCashClient::new(ecocash_creds)) as Arc<dyn payment_engine::domain::provider::ProviderClient>;

    // Initialize handlers
    let initiate_handler = InitiatePaymentHandler::new(
        payment_repo.clone(),
        outbox_repo.clone(),
        ecocash_client.clone(),
    );
    let callback_handler =
        ProcessCallbackHandler::new(payment_repo.clone(), outbox_repo.clone(), ecocash_client);

    // Build gRPC server
    let grpc_server = PaymentGrpcServer {
        initiate_handler,
        callback_handler,
        payment_repo,
    };

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr: SocketAddr = format!("{}:{}", bind_addr, grpc_port).parse()?;
    info!("gRPC server listening on {}", addr);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    if tls_enabled {
        info!("TLS enabled for payment-engine");
        let tls_config = ussd_kernel_common::tls::load_server_tls_config(
            &cert_path,
            &key_path,
            &ca_path,
        )?;

        Server::builder()
            .tls_config(tls_config)?
            .add_service(PaymentEngineServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    } else {
        Server::builder()
            .add_service(PaymentEngineServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    }

    info!("Payment-engine service shutdown complete");
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
