#!/usr/bin/env bash
# Detached native supervisor wrapper. Full replay/blocker rediscovery is out of scope.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
STATE_PATH="${STATE_PATH:-$DATADIR/chainstate-rocksdb}"
CHECK_SEC="${CHECK_SEC:-120}"
LOCK_FILE="$DATADIR/.sync_supervisor.lock"
PID_FILE="$DATADIR/.sync_supervisor.pid"
TICK_FILE="$DATADIR/.sync_supervisor_tick.json"
STOP_FILE="$DATADIR/.stop_sync"

mkdir -p "$DATADIR"
echo $$ >"$PID_FILE"

exec 9>>"$LOCK_FILE"
"$PY" -c "import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)" 9<&9

exec "$PY" -m pybitnode.supervisor run \
  --state-path "$STATE_PATH" \
  --tick-path "$TICK_FILE" \
  --stop-path "$STOP_FILE" \
  --check-sec "$CHECK_SEC"
