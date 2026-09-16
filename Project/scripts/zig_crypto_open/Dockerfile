# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential=12.9 gcc=4:12.2.0-3 gcc-12=12.2.0-14+deb12u1 g++=4:12.2.0-3 g++-12=12.2.0-14+deb12u1 binutils=2.40-2 cmake=3.25.1-1 pkg-config librocksdb-dev=7.8.3-2 && rm -rf /var/lib/apt/lists/*
RUN arch="$(dpkg --print-architecture)"; case "$arch" in arm64) a=aarch64; sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17;; amd64) a=x86_64; sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00;; *) exit 1;; esac; curl -fsSL "https://ziglang.org/download/0.16.0/zig-${a}-linux-0.16.0.tar.xz" -o /tmp/zig.tar.xz && echo "$sha  /tmp/zig.tar.xz" | sha256sum -c - && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && ln -s /opt/zig/zig /usr/local/bin/zig
ARG C_WINDOW=15
ARG C_TARGET=generic
ARG C_LTO=OFF
ARG BACKEND=own_curve
ARG SOURCE_DIGEST
ARG PROBE=false
ARG REJECT=
COPY reference.tar.gz /tmp/reference.tar.gz
RUN if [ "$BACKEND" = c_binding ]; then echo '385c115a21ee1ff31d0b0320acc2b278c92f7bde971f510566ad481a38835be0  /tmp/reference.tar.gz' | sha256sum -c - && mkdir /tmp/reference && tar -xzf /tmp/reference.tar.gz -C /tmp/reference --strip-components=1 && if [ "$C_WINDOW" -gt 15 ]; then gcc -O2 -DECMULT_WINDOW_SIZE=$C_WINDOW /tmp/reference/src/precompute_ecmult.c -o /tmp/reference-precompute && (cd /tmp/reference && /tmp/reference-precompute); fi && cmake -S /tmp/reference -B /tmp/reference-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DSECP256K1_ASM=OFF -DSECP256K1_ECMULT_WINDOW_SIZE=$C_WINDOW -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$C_LTO -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG $(if [ "$C_TARGET" = native ]; then echo -mcpu=native; fi)" -DSECP256K1_BUILD_TESTS=OFF -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF -DSECP256K1_BUILD_BENCHMARK=OFF -DCMAKE_INSTALL_PREFIX=/usr/local && cmake --build /tmp/reference-build -j4 && cmake --install /tmp/reference-build; fi
COPY Nodes /src/Nodes
COPY Libraries /src/Libraries
WORKDIR /src/Nodes/Zig
RUN --mount=type=cache,target=/root/.cache/zig zig build -Doptimize=ReleaseSafe -Dcrypto-backend=$BACKEND -Dcrypto-source-digest=$SOURCE_DIGEST -Dcrypto-probe=$PROBE -Dcrypto-reject=$REJECT && mkdir /out && cp zig-out/bin/zigbitnode /out/
COPY bench /bench
RUN if [ "$BACKEND" = own_curve ]; then zig build-exe -O ReleaseSafe --dep secp256k1 -Mroot=/bench/bench.zig -O ReleaseSafe -Msecp256k1=/src/Libraries/Zig/libsecp256k1-zig/src/root.zig -femit-bin=/out/component-bench; else zig build-exe -O ReleaseSafe --dep secp256k1 -Mroot=/bench/bench.zig -O ReleaseSafe -I/usr/local/include -L/usr/local/lib -lc -lsecp256k1 -Msecp256k1=/bench/c_control.zig -femit-bin=/out/component-bench; fi
RUN if [ "$BACKEND" = c_binding ]; then cp -a /usr/local/lib/libsecp256k1.so* /out/; fi
RUN dpkg-query -W > /out/build-packages.txt && zig version > /out/zig-version.txt && cc --version > /out/c-compiler.txt && if [ "$BACKEND" = c_binding ]; then sha256sum /usr/local/lib/libsecp256k1.so > /out/c-library-sha256.txt; fi
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb
RUN apt-get update && apt-get install -y --no-install-recommends librocksdb7.8=7.8.3-2 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
RUN if [ -e /usr/local/bin/libsecp256k1.so ]; then mv /usr/local/bin/libsecp256k1.so* /usr/local/lib/ && ldconfig; fi
CMD ["zigbitnode"]
