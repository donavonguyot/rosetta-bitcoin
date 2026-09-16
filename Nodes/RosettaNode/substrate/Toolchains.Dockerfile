FROM rosettanode-substrate:instrument
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*
COPY go.tar.gz rust.tar.xz zig.tar.xz /archives/
RUN mkdir -p /opt/zig /opt/rust /unpack && tar xzf /archives/go.tar.gz -C /opt && tar xJf /archives/zig.tar.xz -C /opt/zig --strip-components=1 && tar xJf /archives/rust.tar.xz -C /unpack && /unpack/rust-1.98.1-aarch64-unknown-linux-gnu/install.sh --prefix=/opt/rust --disable-ldconfig && rm -rf /unpack && sha256sum /archives/* > /opt/toolchain-archives.sha256 && rm -rf /archives
ENV PATH="/opt/go/bin:/opt/rust/bin:/opt/zig:/usr/bin:/bin"
ENV GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local CARGO_NET_OFFLINE=true
WORKDIR /workspace
