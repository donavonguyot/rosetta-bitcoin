FROM elixir:1.16-otp-26 AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git pkg-config librocksdb-dev libsecp256k1-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY mix.exs ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod
COPY lib ./lib
COPY c_src ./c_src
RUN MIX_ENV=prod mix compile

FROM elixir:1.16-otp-26

RUN apt-get update \
  && apt-get install -y --no-install-recommends librocksdb7.8 libsecp256k1-1 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /workspace ./

ENV MIX_ENV=prod
ENV DATA_DIR=/data
ENV CHAIN=testnet4
ENV CHAINSTATE_BACKEND=rocksdb
ENV SECP256K1_BACKEND=native
ENV RUNTIME_SURFACE=docker

RUN useradd --create-home --uid 10001 exbitnode \
  && mkdir -p /data \
  && chown -R exbitnode:exbitnode /data /app

USER exbitnode
RUN mix local.hex --force && mix local.rebar --force
VOLUME ["/data"]

CMD ["mix", "node.status"]
