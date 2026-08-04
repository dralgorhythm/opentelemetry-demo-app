use clap::Parser;
use opentelemetry::trace::TracerProvider;
use opentelemetry::KeyValue;
use opentelemetry_otlp::Protocol;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::Resource;
use tracing_subscriber::{filter::EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

mod config;
mod handlers;
mod middleware;
mod routes;

/// The build this binary was cut from — the commit SHA CI passes as the
/// `BUILD_SHA` docker build-arg, baked in at compile time.
///
/// `option_env!`, not `env!`: a bare `cargo run` has no BUILD_SHA and must
/// still compile, so local builds report "dev". That fallback is also the
/// honest answer — an unstamped binary genuinely doesn't know its build.
///
/// This is what makes "deploy green but the OLD version is serving"
/// detectable: it rides `service.version` on every span and the `/healthz`
/// body, and `EXPECT_SHA=<sha> scripts/smoke.sh cloud` asserts it.
pub fn build_sha() -> &'static str {
    option_env!("BUILD_SHA").unwrap_or("dev")
}

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Config file path
    #[arg(short = 'f', long = "config-file")]
    config_file: Option<String>,
}

fn setup_tracing() -> Result<opentelemetry_sdk::trace::SdkTracerProvider, Box<dyn std::error::Error>>
{
    // W3C trace-context propagator, registered GLOBALLY because both
    // directions need it: middleware.rs asks for it by
    // global::get_text_map_propagator to EXTRACT an inbound `traceparent`,
    // and any future outbound client asks for it to inject one.
    //
    // Without this the SDK has a no-op propagator: every inbound request
    // started a brand-new trace and the caller's trace id was silently
    // dropped, so a request crossing into this service appeared as two
    // unrelated traces. That is invisible in a single-service demo and
    // fatal the moment a second service exists — which is exactly why it is
    // worth fixing while the app is still small enough to verify by hand.
    opentelemetry::global::set_text_map_propagator(TraceContextPropagator::new());

    // Initialize OpenTelemetry tracing
    let otlp_endpoint = std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://127.0.0.1:4317".to_string());

    // Initialize OTLP exporter using gRPC (tonic)
    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_protocol(Protocol::Grpc)
        .with_endpoint(otlp_endpoint)
        .build()?;

    // service.name from OTEL_SERVICE_NAME (deploy/services/app.yaml sets
    // "app" — the release/SA/ECR identity); crate name is the local-dev
    // fallback.
    let service_name =
        std::env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| "opentelemetry-demo-app".to_string());

    // Create tracer provider
    let tracer_provider = opentelemetry_sdk::trace::TracerProviderBuilder::default()
        .with_batch_exporter(exporter)
        .with_resource(
            Resource::builder()
                .with_attribute(KeyValue::new("service.name", service_name))
                // service.version rides EVERY span, so X-Ray can answer
                // "which build produced this latency?" without correlating
                // by deploy timestamp.
                .with_attribute(KeyValue::new("service.version", build_sha()))
                .build(),
        )
        .build();

    let tracer = tracer_provider.tracer("opentelemetry-demo-app");

    // Initialize tracing subscriber with OpenTelemetry layer.
    //
    // JSON, not the human formatter: the CloudWatch observability add-on's
    // Fluent Bit parses a JSON log line and nests it under `log_processed`
    // (Merge_Log_Key), which is what the saved Logs Insights queries and the
    // dashboard's p95 widget read — see terraform/modules/stack/alerting.tf.
    // Text logs left every one of those returning zero rows.
    //
    // Do NOT add .flatten_event(true): it lifts event fields to the top
    // level, and those queries address them as log_processed.fields.* (the
    // formatter's default nesting). The producing event lives in
    // middleware.rs ("HTTP request completed" with status_code/latency_ms)
    // and already carried the right fields — only the encoding was wrong.
    //
    // Local runs stay readable via `| jq`; docker-compose's Jaeger UI is the
    // nicer local view either way.
    tracing_subscriber::registry()
        .with(EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer().json())
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
