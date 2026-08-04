use axum::{routing::get, Router};
use bb8_redis::{bb8, RedisConnectionManager};
use std::sync::Arc;

use crate::handlers;
use crate::middleware;

pub async fn build_router(redis_url: &str) -> Result<Router, Box<dyn std::error::Error>> {
    // Initialize Redis connection pool
    let manager = RedisConnectionManager::new(redis_url)?;

    let pool = bb8::Pool::builder().build(manager).await?;
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
