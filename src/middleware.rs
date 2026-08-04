use axum::body::Body;
use http::Request;
use opentelemetry_http::HeaderExtractor;
use tower_http::trace::{
    DefaultOnBodyChunk, DefaultOnEos, DefaultOnFailure, MakeSpan, OnRequest, OnResponse, TraceLayer,
};
use tracing::field::Empty;
use tracing_opentelemetry::OpenTelemetrySpanExt;

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

                // Full URL (Opt-in). Current semconv, and the ONLY source of
                // the host for X-Ray: the collector renames this to the
                // old-convention http.url that the awsxray exporter reads
                // (deploy/cluster/otel-collector.yaml). Without it segments
                // carry "http:///path" — host-less, so no X-Ray URL filter
                // can tell environments apart.
                "url.full" = Empty,

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

            // url.full = scheme://host/path[?query]. Built from the Host
            // header, so it reflects the edge the client actually addressed
            // (the ALB hostname), which is exactly what makes it useful for
            // telling dev from staging in an X-Ray URL filter. Skipped
            // entirely when there is no Host header — a synthesized URL that
            // claims a host nobody sent would be worse than an absent one.
            if let Some(host) = host_header {
                let full = match query {
                    Some(q) => format!("{scheme}://{host}{path}?{q}"),
                    None => format!("{scheme}://{host}{path}"),
                };
                span.record("url.full", full.as_str());
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

            // Span name = method + ROUTE TEMPLATE, never the concrete path.
            //
            // This is OTel's own rule for server spans, and here it is also a
            // load-bearing X-Ray fix: the awsxray exporter labels service-map
            // nodes from the local-root span name, so a name carrying the raw
            // path minted ONE NODE PER URL. Observed live as segments named
            // `GET /smoke-30958213453-1785884357` — every smoke run, every
            // scanner probe, its own permanent node. It is also why
            // `service("app")` matched zero traces and PR #17's trace gate had
            // to filter on http.url instead.
            //
            // MatchedPath is the router's template (`/` stays `/`; a future
            // `/users/{id}` stays `/users/{id}` rather than exploding per id).
            // Absent when nothing matched — 404s, which are exactly the
            // unbounded case — and OTel says to use the bare method there
            // rather than invent a template.
            let span_name = match request.extensions().get::<axum::extract::MatchedPath>() {
                Some(matched) => {
                    // http.route was declared on the span and never recorded.
                    // Populating it is what makes the X-Ray annotation of the
                    // same name (otel-collector.yaml indexed_attributes) hold
                    // anything — and it is the low-cardinality key you want to
                    // filter by, unlike the concrete url.path.
                    span.record("http.route", matched.as_str());
                    format!("{} {}", method, matched.as_str())
                }
                None => method.to_string(),
            };
            span.record("otel.name", &span_name);

            // Adopt the CALLER's trace, if it sent one. The global
            // propagator (registered in main.rs) reads the W3C `traceparent`
            // header; with no header, extract() yields an empty context and
            // set_parent leaves this span as a new root — so an unadorned
            // curl behaves exactly as before.
            //
            // This must happen AFTER the span exists, because the parent is
            // attached to the span rather than passed at construction.
            //
            // Prove it by hand:
            //   curl -H 'traceparent: 00-<32 hex>-<16 hex>-01' http://$HOST/
            // then look for that trace id in X-Ray — the request joins the
            // caller's trace instead of starting an unrelated one.
            let parent_cx = opentelemetry::global::get_text_map_propagator(|propagator| {
                propagator.extract(&HeaderExtractor(headers))
            });
            span.set_parent(parent_cx);

            span
        })
        .on_response(
            |response: &http::Response<_>, latency: std::time::Duration, span: &tracing::Span| {
                // `as i64` is load-bearing, exactly like the latency_ms cast
                // below. tracing records u16 as u64, and tracing-opentelemetry
                // has no unsigned OTel attribute type to map that onto, so it
                // STRINGIFIES: the span carried Str("200"). X-Ray's
                // http.status_code must be an integer, so a string left every
                // segment at status 0 — no error classification, no service-map
                // error rate, `http.status = 500` matching nothing. i64 maps
                // to OTel Int and survives the whole path.
                span.record(
                    "http.response.status_code",
                    response.status().as_u16() as i64,
                );

                // Record response content length if available
                if let Some(content_length) = response
                    .headers()
                    .get("content-length")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|s| s.parse::<u64>().ok())
                {
                    span.record("http.response.body.size", content_length);
                }

                // `as u64` is load-bearing, not a lint fix. Duration::as_millis
                // returns u128, and `tracing` has no Value impl for u128 — it
                // falls back to Debug recording, which serializes as the STRING
                // "5" instead of the number 5. CloudWatch Logs Insights can't
                // avg()/pct() a string, so the dashboard's p95 widget and the
                // p95-by-service saved query (terraform/modules/stack/
                // alerting.tf) would still return empty with JSON logs on.
                // u64 milliseconds overflows after ~584 million years.
                tracing::info!(
                    status_code = response.status().as_u16(),
                    latency_ms = latency.as_millis() as u64,
                    "HTTP request completed"
                );
            },
        )
}
