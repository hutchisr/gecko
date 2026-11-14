FROM rust:1-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/gecko-push-proxy /usr/local/bin/gecko-push-proxy
COPY LICENSE /usr/share/licenses/gecko-push-proxy/LICENSE
# Mount the APNs .p8 key read-only, e.g. at /secrets/apns.p8.
USER nobody
ENTRYPOINT ["/usr/local/bin/gecko-push-proxy"]
