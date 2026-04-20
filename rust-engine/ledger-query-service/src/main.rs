use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tonic::transport::Server;
use tracing::{error, info};

use ussd_kernel_common::v1::ledger::ledger_query_service_server::LedgerQueryServiceServer;
use ussd_kernel_common::v1::ledger::virtual_account_service_server::VirtualAccountServiceServer;
use ussd_kernel_common::v1::ledger::liquidity_position_service_server::LiquidityPositionServiceServer;
use ussd_kernel_common::v1::ledger::settlement_service_server::SettlementServiceServer;
use ussd_kernel_common::v1::ledger::suspense_service_server::SuspenseServiceServer;
use ussd_kernel_common::v1::ledger::chart_of_accounts_service_server::ChartOfAccountsServiceServer;

use ledger_query_service::application::handler::LedgerQueryHandler;
use ledger_query_service::infrastructure::postgres_read_model::PostgresReadModel;
use ledger_query_service::ports::grpc::LedgerQueryGrpcServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if let Err(e) = dotenvy::dotenv() {
        tracing::debug!(".env file not found or unreadable: {}", e);
    }

    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    info!("Starting ledger-query-service");
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
        .unwrap_or(50057u16);

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    info!("Database pool initialized");

    let read_model = Arc::new(PostgresReadModel::new(pool)) as Arc<dyn ledger_query_service::ports::read_model::ReadModelPort>;
    let handler = LedgerQueryHandler::new(read_model);

    let grpc_server = LedgerQueryGrpcServer { handler };

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr: SocketAddr = format!("{}:{}", bind_addr, grpc_port).parse()?;
    info!("gRPC server listening on {}", addr);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    // NOTE: The Open AI-USSD Kernel Engine is NOT a financial system.
    // Ledger query services (account balances, statements, settlements,
    // suspense items, virtual accounts, chart of accounts) are out of scope
    // for a USSD kernel providing mobile money payment adapters only.
    // Financial gRPC services remain registered for backward compat but bind
    // to localhost by default so they are NOT reachable from the network.
    info!("ledger-query-service started with financial APIs bound to localhost only (out of scope for payment kernel)");

    if tls_enabled {
        info!("TLS enabled for ledger-query-service");
        let tls_config = ussd_kernel_common::tls::load_server_tls_config(
            &cert_path,
            &key_path,
            &ca_path,
        )?;

        Server::builder()
            .tls_config(tls_config)?
            .add_service(LedgerQueryServiceServer::new(grpc_server.clone()))
            .add_service(VirtualAccountServiceServer::new(grpc_server.clone()))
            .add_service(LiquidityPositionServiceServer::new(grpc_server.clone()))
            .add_service(SettlementServiceServer::new(grpc_server.clone()))
            .add_service(SuspenseServiceServer::new(grpc_server.clone()))
            .add_service(ChartOfAccountsServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    } else {
        Server::builder()
            .add_service(LedgerQueryServiceServer::new(grpc_server.clone()))
            .add_service(VirtualAccountServiceServer::new(grpc_server.clone()))
            .add_service(LiquidityPositionServiceServer::new(grpc_server.clone()))
            .add_service(SettlementServiceServer::new(grpc_server.clone()))
            .add_service(SuspenseServiceServer::new(grpc_server.clone()))
            .add_service(ChartOfAccountsServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    }

    info!("ledger-query-service shutdown complete");
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
