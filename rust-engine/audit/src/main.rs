use std::env;
use std::net::SocketAddr;
use std::time::Duration;

use chrono::Utc;
use sqlx::postgres::PgPoolOptions;
use tokio::signal;
use tokio::time::{interval_at, Instant};
use tonic::transport::Server;
use tracing::{error, info, warn};

use ussd_kernel_common::v1::audit::audit_service_server::AuditServiceServer;

use audit_service::application::audit::AuditHandler;
use audit_service::infrastructure::postgres::AuditRepository;
use audit_service::infrastructure::signing::load_signing_key;
use audit_service::ports::grpc::AuditGrpcServer;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    ussd_kernel_common::telemetry::init_tracing(env!("CARGO_PKG_NAME"));

    info!("Starting audit-service");
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
        .unwrap_or(50054u16);

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    info!("Database pool initialized");

    let repo = AuditRepository::new(pool.clone());
    let signer = load_signing_key();
    let handler = AuditHandler::new(repo.clone(), signer);
    let grpc_server = AuditGrpcServer::new(handler.clone());

    // Spawn the daily batch hash cron job (M1 regulatory requirement)
    let cron_handler = handler.clone();
    tokio::spawn(async move {
        run_daily_batch_cron(cron_handler).await;
    });

    let bind_addr = env::var("BIND_ADDRESS").unwrap_or_else(|_| "127.0.0.1".into());
    let addr: SocketAddr = format!("{}:{}", bind_addr, grpc_port).parse()?;
    info!("gRPC server listening on {}", addr);

    let cert_path = env::var("TLS_CERT_FILE").unwrap_or_default();
    let key_path = env::var("TLS_KEY_FILE").unwrap_or_default();
    let ca_path = env::var("TLS_CA_FILE").unwrap_or_default();

    let tls_enabled = !cert_path.is_empty() && !key_path.is_empty() && !ca_path.is_empty();

    if tls_enabled {
        info!("TLS enabled for audit-service");
        let tls_config = ussd_kernel_common::tls::load_server_tls_config(
            &cert_path,
            &key_path,
            &ca_path,
        )?;

        Server::builder()
            .tls_config(tls_config)?
            .add_service(AuditServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    } else {
        Server::builder()
            .add_service(AuditServiceServer::new(grpc_server))
            .serve_with_shutdown(addr, shutdown_signal())
            .await?;
    }

    info!("Audit-service shutdown complete");
    Ok(())
}

/// Daily cron job: compute Merkle root for the previous day and write to
/// `integrity.batch_hashes` with an Ed25519 signature.
///
/// Runs at 02:00 UTC every day. On startup, it also backfills any missing
/// daily hashes for the last 7 days.
async fn run_daily_batch_cron(handler: AuditHandler) {
    // Backfill last 7 days on startup
    let today = Utc::now().date_naive();
    for days_back in 1..=7 {
        let date = today - chrono::Duration::days(days_back);
        match handler.compute_daily_batch(date).await {
            Ok(record) => {
                info!(
                    batch_date = %date,
                    batch_hash = %record.batch_hash,
                    record_count = record.record_count,
                    "Backfilled daily batch hash"
                );
            }
            Err(e) => {
                warn!(batch_date = %date, error = %e, "Failed to backfill daily batch hash");
            }
        }
    }

    // Schedule next run at 02:00 UTC
    let now = Utc::now();
    let mut next_run = now.date_naive().and_hms_opt(2, 0, 0).unwrap().and_utc();
    if next_run <= now {
        next_run += chrono::Duration::days(1);
    }
    let wait_duration = (next_run - now).to_std().unwrap_or(Duration::from_secs(60));

    info!(
        next_run = %next_run,
        "Daily batch hash cron scheduled"
    );

    let start = Instant::now() + wait_duration;
    let mut ticker = interval_at(start, Duration::from_secs(24 * 60 * 60));

    loop {
        ticker.tick().await;
        let yesterday = Utc::now().date_naive() - chrono::Duration::days(1);
        match handler.compute_daily_batch(yesterday).await {
            Ok(record) => {
                info!(
                    batch_date = %yesterday,
                    batch_hash = %record.batch_hash,
                    record_count = record.record_count,
                    "Daily batch hash computed and signed successfully"
                );
            }
            Err(e) => {
                error!(
                    batch_date = %yesterday,
                    error = %e,
                    "CRITICAL: Daily batch hash computation failed"
                );
            }
        }
    }
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
