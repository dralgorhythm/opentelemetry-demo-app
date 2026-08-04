use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bb8_redis::{bb8, redis::AsyncCommands, RedisConnectionManager};
use std::sync::Arc;
use tracing::Instrument;

// Dependency-free on purpose: liveness/readiness must not couple pod health
// to Redis availability (a dependency outage that restarts pods or empties
// every endpoint from rotation makes the blip worse, and GET / already
// reports it honestly as a 500).
//
// The build stamp rides here rather than on a separate /version route: this
// is already the one endpoint every probe and the smoke gate hit, and
// "ok <sha>" keeps the existing `contains "ok"` assert true. Still
// dependency-free — build_sha() is a compile-time constant.
//
// Note this makes the served commit SHA publicly readable through the ALB.
// Accepted: the repo is public, and knowing which build is live is the
// entire point of the stamp. A private deployment would move this behind
// the /version route and an auth check.
pub async fn healthz() -> String {
    format!("ok {}", crate::build_sha())
}

pub async fn hello_world(
    axum::extract::State(pool): axum::extract::State<Arc<bb8::Pool<RedisConnectionManager>>>,
) -> Response {
    // Get a connection from the pool
    let mut conn = match pool.get().await {
        Ok(conn) => {
            tracing::debug!("Successfully obtained Redis connection from pool");
            conn
        }
        Err(e) => {
            // Log the CAUSE — a bare "failed" line made the first in-cluster
            // Redis outage undiagnosable from pod logs (SG? TLS? AUTH? all
            // look identical from outside).
            tracing::error!(error = %e, "Failed to get database connection from pool");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to get database connection",
            )
                .into_response();
        }
    };

    // Ideally we'd have an InstrumentedAsyncCommands trait to use which
    // generates spans automatically, but here we are.
    let span = tracing::info_span!(
        "INCRBY visit_counter",
        db.system = "redis",
        db.operation.name = "INCRBY",
        db.collection.name = "visit_counter",
        db.statement = "INCRBY visit_counter 1",
    );

    // Increment the visit counter in Redis
    let visit_count: i32 = match conn.incr("visit_counter", 1).instrument(span).await {
        Ok(count) => count,
        Err(e) => {
            tracing::error!(error = %e, "Failed to increment visit counter in Redis");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "Failed to increment visit counter",
            )
                .into_response();
        }
    };

    (
        StatusCode::OK,
        format!("Hello, World! You are visitor number {}", visit_count),
    )
        .into_response()
}
