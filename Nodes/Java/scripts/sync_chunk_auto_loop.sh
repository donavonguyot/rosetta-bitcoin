#!/usr/bin/env bash
# Deprecated wrapper — use scripts/sync_supervisor.sh via `make java-node-sync-supervisor`.
set -euo pipefail
cd "$(dirname "$0")/.."
export CHUNK_TOTAL="${CHUNK_TOTAL:-15000}"
export SUBCHUNK_SIZE="${SUBCHUNK_SIZE:-500}"
export DATA_DIR="${DATA_DIR:-./data-java}"
export PEERS="${PEERS:-127.0.0.1:48333}"
export LOG="${LOG:-sync_chunk_auto.log}"
exec ./scripts/sync_supervisor.sh
