FROM node:20-slim AS build

WORKDIR /app

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

USER tsbitnode

VOLUME ["/data"]
# Default chain is testnet4; P2P listens on 48333 when LISTEN is enabled (see compose).
EXPOSE 48333

# Same as compose: `validateHealthcheckPayload` + sync_status!="error"; JSON on stdout.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["node", "dist/cli/healthcheck.js"]

CMD ["node", "dist/cli/node.js", "--datadir", "/data"]
