# syntax=docker/dockerfile:1.7
FROM golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db AS build
ARG CRYPTO_BACKEND=c_binding
ARG CRYPTO_SOURCE_DIGEST=unrecorded
ARG CRYPTO_PROBE=false

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential pkg-config librocksdb-dev $(test "$CRYPTO_BACKEND" = own_curve || echo libsecp256k1-dev) \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/Nodes/Go
COPY Nodes/Go/go.mod Nodes/Go/go.sum ./
COPY Libraries/Go/libsecp256k1-go /src/Libraries/Go/libsecp256k1-go
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY Nodes/Go .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode ./cmd/gobitnode \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-sync ./cmd/gobitnode-sync \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-connect ./cmd/gobitnode-connect \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-status ./cmd/gobitnode-status \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-storage-proof ./cmd/gobitnode-storage-proof \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-script-corpus ./cmd/gobitnode-script-corpus \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-blocker-inspect ./cmd/gobitnode-blocker-inspect \
    && go build -ldflags "-X rosettabitcoin/nodes/go/internal/crypto.SourceDigest=$CRYPTO_SOURCE_DIGEST" -tags "$(test "$CRYPTO_BACKEND" = own_curve && echo owncurve || true)$(test "$CRYPTO_PROBE" = true && echo ,cryptoprobe || true)" -o /out/gobitnode-local-reference-proof ./cmd/gobitnode-local-reference-proof

FROM debian:bookworm-slim
ARG CRYPTO_BACKEND=c_binding

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates librocksdb7.8 $(test "$CRYPTO_BACKEND" = own_curve || echo libsecp256k1-1) \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/gobitnode /usr/local/bin/gobitnode
COPY --from=build /out/gobitnode-sync /usr/local/bin/gobitnode-sync
COPY --from=build /out/gobitnode-connect /usr/local/bin/gobitnode-connect
COPY --from=build /out/gobitnode-status /usr/local/bin/gobitnode-status
COPY --from=build /out/gobitnode-storage-proof /usr/local/bin/gobitnode-storage-proof
COPY --from=build /out/gobitnode-script-corpus /usr/local/bin/gobitnode-script-corpus
COPY --from=build /out/gobitnode-blocker-inspect /usr/local/bin/gobitnode-blocker-inspect
COPY --from=build /out/gobitnode-local-reference-proof /usr/local/bin/gobitnode-local-reference-proof
COPY Nodes/Go/scripts/docker_supervisor_once.sh /usr/local/bin/gobitnode-supervisor-once

ENV CHAIN=testnet4
ENV DATA_DIR=/data

RUN useradd --create-home --uid 10001 gobitnode \
    && mkdir -p /data /results \
    && chown -R gobitnode:gobitnode /data /results

USER gobitnode
VOLUME ["/data"]
EXPOSE 48333

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["gobitnode-status", "--datadir", "/data"]

CMD ["gobitnode", "status", "--datadir", "/data"]
