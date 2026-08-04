# Single-arch linux/amd64 image (CI runners are amd64; in-cluster pods pin
# kubernetes.io/arch: amd64). Build locally on Apple Silicon with
# `docker build --platform linux/amd64 .`
#
# Static musl build so the runtime stage is a distroless-style static image
# (chainguard/static: CA bundle present, nonroot uid 65532, no shell).
FROM rust:1-slim-bookworm@sha256:99e09cb2284e2ddbb73a995deee3e91783fd04d177602ccf6eab326d778ee777 AS build
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends musl-tools \
 && rm -rf /var/lib/apt/lists/*
RUN rustup target add x86_64-unknown-linux-musl
WORKDIR /src
# Dependency layer: compile deps against a stub main so code-only changes
# never rebuild the dependency graph. The rm of this crate's own artifacts
# forces a relink of the real src/ while keeping every dependency cached.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
 && cargo build --release --locked --target x86_64-unknown-linux-musl \
 && rm -rf src target/x86_64-unknown-linux-musl/release/deps/opentelemetry_demo_app*
COPY src ./src
RUN cargo build --release --locked --target x86_64-unknown-linux-musl

FROM cgr.dev/chainguard/static:latest@sha256:399c8cb4858f05aaa33f43f02a2e75f28d40f016c0f86e5ba6075769e3303791
COPY --from=build /src/target/x86_64-unknown-linux-musl/release/opentelemetry-demo-app /app
EXPOSE 8080
# No config baked in: the chart passes `-f /mnt/secrets-store/config.yml`
# via container args; locally, mount one and pass -f yourself.
ENTRYPOINT ["/app"]
