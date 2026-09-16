# syntax=docker/dockerfile:1.7
ARG ZIG_VERSION=0.16.0

FROM debian:bookworm-slim AS build
ARG ZIG_VERSION
ARG CRYPTO_BACKEND=c_binding
ARG CRYPTO_SOURCE_DIGEST=unrecorded
ARG CRYPTO_PROBE=false
ARG CRYPTO_REJECT=
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential librocksdb-dev $(test "$CRYPTO_BACKEND" = own_curve || echo libsecp256k1-dev) pkg-config \
  && rm -rf /var/lib/apt/lists/*
RUN arch="$(dpkg --print-architecture)" \
  && case "$arch" in amd64) zig_arch=x86_64; zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; arm64) zig_arch=aarch64; zig_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac \
  && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
  && printf "%s  /tmp/zig.tar.xz\n" "$zig_sha" | sha256sum -c - \
  && mkdir -p /opt/zig \
  && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
  && ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /src/Nodes/Zig
COPY Nodes/Zig/build.zig Nodes/Zig/build.zig.zon ./
COPY Libraries/Zig/libsecp256k1-zig /src/Libraries/Zig/libsecp256k1-zig
COPY Nodes/Zig/src ./src
COPY Nodes/Zig/tests ./tests
RUN --mount=type=cache,target=/root/.cache/zig \
  --mount=type=cache,target=/src/.zig-cache \
  zig build -Doptimize=ReleaseSafe -Dcrypto-backend=$CRYPTO_BACKEND -Dcrypto-source-digest=$CRYPTO_SOURCE_DIGEST -Dcrypto-probe=$CRYPTO_PROBE -Dcrypto-reject=$CRYPTO_REJECT \
  && mkdir -p /out \
  && cp /src/Nodes/Zig/zig-out/bin/zigbitnode /out/zigbitnode

FROM debian:bookworm-slim
ARG CRYPTO_BACKEND=c_binding
RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev $(test "$CRYPTO_BACKEND" = own_curve || echo libsecp256k1-dev) ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/zigbitnode /usr/local/bin/zigbitnode
CMD ["zigbitnode"]
