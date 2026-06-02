#!/usr/bin/env bash
# Docker/host native supervisor wrapper; does not perform full replay.
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data}"
STATE_PATH="${STATE_PATH:-$DATA_DIR/chainstate-rocksdb}"
CHECK_SEC="${CHECK_SEC:-120}"
TICK_PATH="${TICK_PATH:-$DATA_DIR/.pybitnode-supervisor-tick.json}"
STOP_PATH="${STOP_PATH:-$DATA_DIR/.stop_sync}"

python -m pybitnode.supervisor run \
  --state-path "$STATE_PATH" \
  --tick-path "$TICK_PATH" \
  --stop-path "$STOP_PATH" \
  --check-sec "$CHECK_SEC"
