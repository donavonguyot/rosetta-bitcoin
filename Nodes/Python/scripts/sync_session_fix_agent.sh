#!/usr/bin/env bash
# In-session native-state monitor. It does not perform full replay or consensus fixes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
STATE_PATH="${STATE_PATH:-$DATADIR/chainstate-rocksdb}"
TARGET="${TARGET:-0}"
POLL_SEC="${POLL_SEC:-180}"
MAX_ELAPSED_SEC="${MAX_ELAPSED_SEC:-7200}"
SESSION_LOG="${SESSION_LOG:-$ROOT/sync_session_fix_agent.log}"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$SESSION_LOG"; }

status_json() {
  "$PY" scripts/cursor_sync_monitor.py --state-path "$STATE_PATH" --target "$TARGET" --once 2>/dev/null \
    | sed 's/^AGENT_LOOP_TICK_pybitnode_sync //' || echo '{}'
}

validated_height() {
  status_json | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('validated_height') or 0))"
}

start_ts=$(date +%s)
last_vh=""
last_change_ts=$start_ts

log "native session monitor start target=$TARGET max_elapsed=${MAX_ELAPSED_SEC}s"
while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  vh="$(validated_height)"
  if [[ "$TARGET" =~ ^[0-9]+$ ]] && [[ "$TARGET" -gt 0 ]] && [[ "$vh" -ge "$TARGET" ]]; then
    log "target reached validated_height=$vh"
    exit 0
  fi
  if [[ "$elapsed" -ge "$MAX_ELAPSED_SEC" ]]; then
    log "max elapsed ${MAX_ELAPSED_SEC}s; monitor exit"
    exit 0
  fi
  if [[ "$vh" != "$last_vh" ]]; then
    last_vh="$vh"
    last_change_ts=$now
    log "progress validated_height=$vh"
  else
    stalled=$((now - last_change_ts))
    log "no height change validated_height=$vh stalled_sec=$stalled"
  fi
  sleep "$POLL_SEC"
done
