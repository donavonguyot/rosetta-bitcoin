FROM swift:6.0-jammy AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev libsecp256k1-dev ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release

FROM swift:6.0-jammy

RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb-dev libsecp256k1-dev ca-certificates netcat-openbsd \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /src/.build/release/swiftbitnode /usr/local/bin/swiftbitnode
CMD ["swiftbitnode"]
