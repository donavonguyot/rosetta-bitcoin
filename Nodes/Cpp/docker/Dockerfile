FROM ubuntu:24.04 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential cmake libssl-dev librocksdb-dev libsecp256k1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCPBITNODE_USE_ROCKSDB=ON -DCPBITNODE_USE_NATIVE_SECP256K1=ON \
    && cmake --build build --target cpbitnode cpbitnode-db cpbitnode-healthcheck cpbitnode-sync cpbitnode-storage-proof cpbitnode-blocker-inspect cpbitnode_tests

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends librocksdb8.9 libsecp256k1-1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/cpbitnode /usr/local/bin/cpbitnode
COPY --from=build /src/build/cpbitnode-db /usr/local/bin/cpbitnode-db
COPY --from=build /src/build/cpbitnode-healthcheck /usr/local/bin/cpbitnode-healthcheck
COPY --from=build /src/build/cpbitnode-sync /usr/local/bin/cpbitnode-sync
COPY --from=build /src/build/cpbitnode-storage-proof /usr/local/bin/cpbitnode-storage-proof
COPY --from=build /src/build/cpbitnode-blocker-inspect /usr/local/bin/cpbitnode-blocker-inspect
COPY --from=build /src/build/cpbitnode_tests /usr/local/bin/cpbitnode_tests
COPY --from=build /src/build/cpbitnode /src/build/cpbitnode
COPY --from=build /src/build/cpbitnode-db /src/build/cpbitnode-db
COPY --from=build /src/build/cpbitnode-healthcheck /src/build/cpbitnode-healthcheck
COPY --from=build /src/build/cpbitnode-sync /src/build/cpbitnode-sync
COPY --from=build /src/tests/fixtures /src/tests/fixtures

ENV CHAIN=testnet4
ENV DATA_DIR=/data
ENV CHAINSTATE_BACKEND=rocksdb
ENV LOG_LEVEL=info

RUN useradd --create-home --uid 10001 cpbitnode \
    && mkdir -p /data /src/tests/fixtures/blocks /Nodes/Cpp \
    && chown -R cpbitnode:cpbitnode /data /src

USER cpbitnode
VOLUME ["/data"]
EXPOSE 48333

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["cpbitnode-healthcheck"]

CMD ["cpbitnode", "--datadir", "/data"]
