FROM rust:1-bookworm AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential clang pkg-config librocksdb-dev libclang-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
COPY tests ./tests
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates librocksdb7.8 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/target/release/rsbitnode /usr/local/bin/rsbitnode
COPY scripts/docker_supervisor_once.sh /usr/local/bin/rsbitnode-supervisor-once

ENV CHAIN=testnet4
ENV DATA_DIR=/data

RUN useradd --create-home --uid 10001 rsbitnode \
    && mkdir -p /data /results \
    && chown -R rsbitnode:rsbitnode /data /results \
    && chmod +x /usr/local/bin/rsbitnode-supervisor-once

USER rsbitnode
VOLUME ["/data"]
EXPOSE 48333

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["rsbitnode", "status", "--datadir", "/data", "--runtime-surface", "docker"]

CMD ["rsbitnode", "status", "--datadir", "/data", "--runtime-surface", "docker"]
