FROM node:20-slim AS build

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim

WORKDIR /app

ENV CHAIN=testnet4
ENV DATA_DIR=/data
ENV LOG_LEVEL=info

RUN useradd --create-home --uid 10001 tsbitnode \
    && mkdir -p /data \
    && chown -R tsbitnode:tsbitnode /data /app

COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/package-lock.json ./package-lock.json
COPY --from=build /app/node_modules ./node_modules

USER tsbitnode

VOLUME ["/data"]
# Default chain is testnet4; P2P listens on 48333 when LISTEN is enabled (see compose).
EXPOSE 48333

# Legacy daemon healthcheck remains SQLite-backed while native proof/status use
# `nativeStatus.js` and `storageProof.js`.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["node", "dist/cli/healthcheck.js"]

CMD ["node", "dist/cli/node.js", "--datadir", "/data"]
