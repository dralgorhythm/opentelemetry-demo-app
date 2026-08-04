use axum::{routing::get, Router};
use bb8_redis::{bb8, RedisConnectionManager};
use std::sync::Arc;

use crate::handlers;
use crate::middleware;

// bb8 masks EVERY connect failure as RunError::TimedOut: it retries the
// manager until connection_timeout and discards each cause into a
// NopErrorSink by default. During the first in-cluster outage that made
// SG-vs-TLS-vs-AUTH indistinguishable from the logs. This sink routes every
// discarded cause to the logs instead.
#[derive(Debug, Clone, Copy)]
struct TracingErrorSink;

impl bb8::ErrorSink<bb8_redis::redis::RedisError> for TracingErrorSink {
    fn sink(&self, error: bb8_redis::redis::RedisError) {
        tracing::error!(%error, "redis pool connection error");
    }

    fn boxed_clone(&self) -> Box<dyn bb8::ErrorSink<bb8_redis::redis::RedisError>> {
        Box::new(*self)
    }
}

pub async fn build_router(redis_url: &str) -> Result<Router, Box<dyn std::error::Error>> {
    // Startup preflight with the RAW client, for the same reason as the
    // sink above: one connect attempt whose true error reaches the logs.
    // Non-fatal on purpose — a Redis blip at boot must not crash-loop the
    // pod; GET / degrades to 500 and recovery is automatic.
    match bb8_redis::redis::Client::open(redis_url) {
        Ok(client) => match client.get_multiplexed_async_connection().await {
            Ok(_) => tracing::info!("redis preflight: connect ok"),
            Err(error) => tracing::error!(%error, "redis preflight: connect failed"),
        },
        Err(error) => tracing::error!(%error, "redis preflight: invalid redis_url"),
    }

    // Initialize Redis connection pool
    let manager = RedisConnectionManager::new(redis_url)?;

    let pool = bb8::Pool::builder()
        .error_sink(Box::new(TracingErrorSink))
        .build(manager)
        .await?;
    let pool_arc = Arc::new(pool);

    // Build our application with routes
    // /healthz is registered AFTER the trace layer on purpose: axum layers
    // wrap only previously-added routes, so 10s-interval kubelet probes never
    // generate spans.
    let app = Router::new()
        .route("/", get(handlers::hello_world))
        .layer(middleware::create_trace_layer())
        .route("/healthz", get(handlers::healthz))
        .with_state(pool_arc);

    Ok(app)
}
