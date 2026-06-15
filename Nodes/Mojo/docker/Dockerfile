# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim AS build
ARG MOJO_VERSION=1.0.0b1
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    librocksdb-dev \
    libsecp256k1-dev \
    libssl-dev \
    pkg-config \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:/opt/mojo/bin:${PATH}"
RUN python3 -m venv /opt/mojo \
  && /root/.local/bin/uv pip install --python /opt/mojo/bin/python --prerelease allow "mojo==${MOJO_VERSION}" \
  && /opt/mojo/bin/mojo --version \
  && /opt/mojo/bin/mojo --version | grep -q "${MOJO_VERSION}"
WORKDIR /src
COPY src ./src
COPY tests ./tests
RUN cc -O2 -Wall -Wextra -std=c11 -fPIC -shared \
  -o /usr/local/lib/libmojobitnode_shim.so \
  src/mojo_native_shim.c \
  $(pkg-config --cflags --libs rocksdb libsecp256k1 openssl) \
  -lstdc++
RUN /opt/mojo/bin/mojo run tests/toolchain_smoke.mojo
RUN /opt/mojo/bin/mojo build src/mojobitnode.mojo -o /usr/local/bin/mojobitnode

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    librocksdb-dev \
    libsecp256k1-dev \
    libssl-dev \
    python3 \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/mojo /opt/mojo
COPY --from=build /usr/local/bin/mojobitnode /usr/local/bin/mojobitnode
COPY --from=build /usr/local/lib/libmojobitnode_shim.so /usr/local/lib/libmojobitnode_shim.so
COPY --from=build /src/tests /usr/local/share/mojobitnode/tests
ENV PATH="/opt/mojo/bin:${PATH}" \
    MOJOBITNODE_RUNTIME_SURFACE=docker \
    MOJOBITNODE_SHIM_PATH=/usr/local/lib/libmojobitnode_shim.so
ENTRYPOINT ["mojobitnode"]
