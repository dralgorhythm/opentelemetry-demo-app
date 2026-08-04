use axum::body::Body;
use http::Request;
use tower_http::trace::{
    DefaultOnBodyChunk, DefaultOnEos, DefaultOnFailure, MakeSpan, OnRequest, OnResponse, TraceLayer,
};
use tracing::field::Empty;

pub fn create_trace_layer() -> TraceLayer<
    tower_http::classify::SharedClassifier<tower_http::classify::ServerErrorsAsFailures>,
    impl MakeSpan<Body> + Clone,
    impl OnRequest<Body> + Clone,
    impl OnResponse<Body> + Clone,
    DefaultOnBodyChunk,
    DefaultOnEos,
    DefaultOnFailure,
> {
    TraceLayer::new_for_http()
        .make_span_with(|request: &Request<Body>| {
            let uri = request.uri();
            let method = request.method();
            let headers = request.headers();

            // Extract various components from the URI and request
            let scheme = uri.scheme().map(|s| s.as_str()).unwrap_or("http");
            let path = uri.path();
            let query = uri.query();

            // Get User-Agent header
            let user_agent = headers.get("user-agent").and_then(|h| h.to_str().ok());

            // Get Host header for server.address
            let host_header = headers.get("host").and_then(|h| h.to_str().ok());

            let server_address = host_header.map(|h| {
                // Extract just the hostname part if port is included
                if let Some(colon_pos) = h.rfind(':') {
                    &h[..colon_pos]
                } else {
                    h
                }
            });

            // Extract server port from Host header
            let server_port = host_header.and_then(|h| {
                if let Some(colon_pos) = h.rfind(':') {
                    h[colon_pos + 1..].parse::<u16>().ok()
                } else {
                    // Default ports based on scheme
                    match scheme {
                        "https" => Some(443),
                        "http" => Some(80),
                        _ => None,
                    }
                }
            });

            let span = tracing::info_span!("http_request",
                // Core HTTP attributes (Required)
                "http.request.method" = %method,
                "url.path" = path,
                "url.scheme" = scheme,

                // Query string (Conditionally Required)
                "url.query" = Empty,

                // Server information (Recommended)
                "server.address" = Empty,
                "server.port" = Empty,

                // User agent (Recommended)
                "user_agent.original" = Empty,

                // Network protocol information (Conditionally Required)
                "network.protocol.name" = "http",
                "network.protocol.version" = Empty,

                // Client information (Recommended)
                "client.address" = Empty,
                "client.port" = Empty,
                "network.peer.address" = Empty,
                "network.peer.port" = Empty,

                // Response attributes (set later)
                "http.response.status_code" = Empty,
                "http.route" = Empty,

                // Request/Response size attributes (Opt-in)
                "http.request.size" = Empty,
                "http.request.body.size" = Empty,
                "http.response.size" = Empty,
                "http.response.body.size" = Empty,

                // Network transport (Opt-in)
                "network.transport" = "tcp",

                // OpenTelemetry span name
                "otel.name" = Empty,
            );

            // Set conditional fields after span creation
            if let Some(query_str) = query {
                span.record("url.query", query_str);
            }

            if let Some(addr) = server_address {
                span.record("server.address", addr);
            }

            if let Some(port) = server_port {
                span.record("server.port", port);
            }

            if let Some(ua) = user_agent {
                span.record("user_agent.original", ua);
            }

            // Set HTTP version
            let version = match request.version() {
                http::Version::HTTP_09 => "0.9",
                http::Version::HTTP_10 => "1.0",
                http::Version::HTTP_11 => "1.1",
                http::Version::HTTP_2 => "2",
                http::Version::HTTP_3 => "3",
                _ => "unknown",
            };
            span.record("network.protocol.version", version);

            // Set Content-Length if available for request body size
            if let Some(content_length) = headers
                .get("content-length")
                .and_then(|h| h.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())
            {
                span.record("http.request.body.size", content_length);
            }

            // Set the OpenTelemetry span name (method + path for servers)
            let span_name = format!("{} {}", method, path);
            span.record("otel.name", &span_name);

            span
        })
        .on_response(
            |response: &http::Response<_>, latency: std::time::Duration, span: &tracing::Span| {
                // Record response status code
                span.record("http.response.status_code", response.status().as_u16());

                // Record response content length if available
                if let Some(content_length) = response
                    .headers()
                    .get("content-length")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|s| s.parse::<u64>().ok())
                {
                    span.record("http.response.body.size", content_length);
                }

                tracing::info!(
                    status_code = response.status().as_u16(),
                    latency_ms = latency.as_millis(),
                    "HTTP request completed"
                );
            },
        )
}
