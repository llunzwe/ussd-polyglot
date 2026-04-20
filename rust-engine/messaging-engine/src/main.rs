use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tonic::transport::Server;
use tracing::{error, info};

use ussd_kernel_common::v1::messaging::messaging_service_server::MessagingServiceServer;

use messaging_engine::application::handler::MessagingHandler;
use messaging_engine::infrastructure::{
    ecocash_adapter::EcoCashAdapter, onemoney_adapter::OneMoneyAdapter,
    postgres_delivery::PostgresDeliveryLog, postgres_template::PostgresTemplateStore,
    telecash_adapter::TeleCashAdapter,
};
use messaging_engine::ports::grpc::MessagingGrpcServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    info!("Starting messaging-engine");
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
        .unwrap_or(50055u16);

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    info!("Database pool initialized");

    let ecocash = Arc::new(EcoCashAdapter::new(
        env::var("ECOCASH_BASE_URL").unwrap_or_else(|_| "https://api.ecocash.co.zw".into()),
        env::var("ECOCASH_API_KEY").unwrap_or_else(|_| "demo-key".into()),
        env::var("ECOCASH_API_SECRET").unwrap_or_else(|_| "demo-secret".into()),
    ));

    let onemoney = Arc::new(OneMoneyAdapter::new(
        env::var("ONEMONEY_BASE_URL").unwrap_or_else(|_| "https://api.onemoney.co.zw".into()),
        env::var("ONEMONEY_USERNAME").unwrap_or_else(|_| "demo-user".into()),
        env::var("ONEMONEY_PASSWORD").unwrap_or_else(|_| "demo-pass".into()),
    ));

    let telecash = Arc::new(TeleCashAdapter::new(
        env::var("TELECASH_BASE_URL").unwrap_or_else(|_| "https://api.telecash.co.zw".into()),
        env::var("TELECASH_BEARER_TOKEN").unwrap_or_else(|_| "demo-token".into()),
    ));

    let template_store = Arc::new(PostgresTemplateStore::new(Some(pool.clone())));
    let delivery_log = Arc::new(PostgresDeliveryLog::new(Some(pool.clone())));

    let handler = MessagingHandler::new(
        vec![ecocash, onemoney, telecash],
        template_store,
        delivery_log,
    );

    let grpc_server = MessagingGrpcServer::new(handler);

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr: SocketAddr = format!("{}:{}", bind_addr, grpc_port).parse()?;
    info!("gRPC server listening on {}", addr);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    if tls_enabled {
        info!("TLS enabled for messaging-engine");
        let tls_config =
            ussd_kernel_common::tls::load_server_tls_config(&cert_path, &key_path, &ca_path)?;

        Server::builder()
            .tls_config(tls_config)?
            .add_service(MessagingServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    } else {
        Server::builder()
            .add_service(MessagingServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    }

    info!("Messaging-engine shutdown complete");
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
