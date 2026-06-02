FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libffi-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml ./
COPY pybitnode ./pybitnode

RUN pip install --no-cache-dir .

ENV CHAIN=testnet4
ENV DATA_DIR=/data
ENV STATE_PATH=/data/chainstate-rocksdb
ENV LOG_LEVEL=info

RUN useradd --create-home --uid 10001 pybitnode \
    && mkdir -p /data \
    && chown -R pybitnode:pybitnode /data /app

USER pybitnode

VOLUME ["/data"]
# Default chain is testnet4; P2P listens on 48333 when LISTEN is enabled (see compose).
EXPOSE 48333

# Same as compose: `validate_healthcheck_payload` + sync_status!="error"; JSON on stdout.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["python", "-m", "pybitnode.healthcheck"]

CMD ["python", "-m", "pybitnode", "--datadir", "/data"]
