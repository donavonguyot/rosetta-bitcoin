ARG ZIG_VERSION=0.16.0

FROM debian:bookworm-slim AS build
ARG ZIG_VERSION
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential librocksdb-dev libsecp256k1-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
RUN arch="$(dpkg --print-architecture)" \
  && case "$arch" in amd64) zig_arch=x86_64 ;; arm64) zig_arch=aarch64 ;; *) echo "unsupported arch $arch" >&2; exit 1 ;; esac \
  && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
  && mkdir -p /opt/zig \
  && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
  && ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /src
COPY build.zig ./
COPY src ./src
COPY tests ./tests
RUN zig build -Doptimize=ReleaseFast

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev libsecp256k1-dev ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/zig-out/bin/zigbitnode /usr/local/bin/zigbitnode
CMD ["zigbitnode"]
