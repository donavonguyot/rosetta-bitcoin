FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev binutils librocksdb7.8=7.8.3-2 librocksdb-dev=7.8.3-2 libssl-dev python3 libjson-c-dev && mkdir /packages && cd /packages && apt-get download librocksdb7.8=7.8.3-2 librocksdb-dev=7.8.3-2 && sha256sum *.deb > SHA256SUMS && rm -rf /var/lib/apt/lists/*
WORKDIR /work
