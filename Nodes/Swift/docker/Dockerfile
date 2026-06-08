# syntax=docker/dockerfile:1.7
FROM swift:6.0-bookworm AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev libsecp256k1-dev ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN --mount=type=cache,target=/src/.build \
  --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
  swift build -c release \
  && mkdir -p /out \
  && cp /src/.build/release/swiftbitnode /out/swiftbitnode

FROM swift:6.0-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev libsecp256k1-dev ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/swiftbitnode /usr/local/bin/swiftbitnode
CMD ["swiftbitnode"]
