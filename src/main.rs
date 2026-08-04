use clap::Parser;
use opentelemetry::trace::TracerProvider;
use opentelemetry::KeyValue;
use opentelemetry_otlp::Protocol;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::Resource;
use tracing_subscriber::{filter::EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

mod config;
mod handlers;
mod middleware;
mod routes;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Config file path
    #[arg(short = 'f', long = "config-file")]
    config_file: Option<String>,
}

fn setup_tracing() -> Result<opentelemetry_sdk::trace::SdkTracerProvider, Box<dyn std::error::Error>>
{
    // Initialize OpenTelemetry tracing
    let otlp_endpoint = std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://127.0.0.1:4317".to_string());

    // Initialize OTLP exporter using gRPC (tonic)
    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_protocol(Protocol::Grpc)
        .with_endpoint(otlp_endpoint)
        .build()?;

    // Create tracer provider
    let tracer_provider = opentelemetry_sdk::trace::TracerProviderBuilder::default()
        .with_batch_exporter(exporter)
        .with_resource(
            Resource::builder()
                .with_attribute(KeyValue::new("service.name", "opentelemetry-demo-app"))
                .build(),
        )
        .build();

    let tracer = tracer_provider.tracer("opentelemetry-demo-app");

    // Initialize tracing subscriber with OpenTelemetry layer
    tracing_subscriber::registry()
        .with(EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .with(tracing_opentelemetry::layer().with_tracer(tracer))
        .init();

    // Hand the provider back so run() can shut it down: dropping it here
    // would strand up to a full batch interval of spans on SIGTERM.
    Ok(tracer_provider)
}

fn setup_signal_handler() -> tokio::sync::oneshot::Receiver<()> {
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();

    // Spawn signal handler
    let _signal_handler = tokio::spawn(async move {
        let mut sigint =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).unwrap();
        let mut sigterm =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();

        tokio::select! {
            _ = sigint.recv() => {
                tracing::info!("received SIGINT, initiating graceful shutdown");
            }
            _ = sigterm.recv() => {
                tracing::info!("received SIGTERM, initiating graceful shutdown");
            }
        }

        let _ = shutdown_tx.send(());
    });

    shutdown_rx
}

async fn run(config: config::Config) -> Result<(), Box<dyn std::error::Error>> {
    // Setup tracing and OpenTelemetry
    let tracer_provider = setup_tracing()?;

    // Build the router
    let app = routes::build_router(&config.redis_url).await?;

    // Run it
    let listener = tokio::net::TcpListener::bind(&config.listen_socket_addr()?).await?;
    tracing::info!(listen_address = %config.listen_address, "listening");

    // Setup graceful shutdown
    let shutdown_rx = setup_signal_handler();

    // Serve with graceful shutdown
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            shutdown_rx.await.ok();
            tracing::info!("graceful shutdown initiated");
        })
        .await?;

    // Flush buffered spans before exit — the batch exporter holds up to a
    // full interval of spans that would otherwise be dropped on SIGTERM.
    if let Err(error) = tracer_provider.shutdown() {
        tracing::warn!(%error, "tracer provider shutdown failed; final spans may be lost");
    }

    tracing::info!("server shutdown complete");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    // Load config from file (use CLI arg or default to "config.yml")
    let config_file_path = args.config_file.as_deref().unwrap_or("config.yml");
    let config = config::Config::load_from_file(config_file_path)?;

    match run(config).await {
        Ok(_) => Ok(()),
        Err(error) => {
            tracing::error!(%error, "unrecoverable error encountered; application is shutting down");
            std::process::exit(1);
        }
    }
}
