#!/usr/bin/env bash
# sync_persistent_supervisor.sh — detached infinite sync supervisor (survives agent/session exit).
#
# Loops until validated_height >= TARGET (default 136343, override with env TARGET).
# Each iteration runs scripts/sync_batch_loop.sh with --max-batches 50.
#
# Exit handling (from sync_batch_loop.py):
#   0  progress or target reached — continue outer loop immediately
#   4  max batches — restart outer loop immediately
#   5  consensus stall — write data/.sync_stall.json, sleep 60, retry (supervisor keeps running)
#   *  other/crash — sleep 30, retry
#
# Single instance: fcntl exclusive lock on data/.sync_supervisor.lock (macOS-safe via Python).
# Logs: sync_supervisor.log (timestamped). PID: data/.sync_supervisor.pid
#
# Launch detached (parent should become init/launchd, not agent shell):
#   cd PythonNode
#   ./scripts/launch_detached.sh ./scripts/sync_persistent_supervisor.sh >>./sync_supervisor.log 2>&1
#   echo $! > ./data/.sync_supervisor.pid
#   disown
# (macOS: use launch_detached.sh — no setsid(1); Linux: uses setsid when available)
#
# Companion: scripts/sync_fix_agent_loop.sh (signals FIX_NEEDED for repeated stalls).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
TARGET="${TARGET:-136343}"
BATCH_TARGET="${BATCH_TARGET:-$TARGET}"
BLOCKS_MAX="${BLOCKS_MAX:-200}"
MAX_BATCHES="${MAX_BATCHES:-50}"
STALL_SLEEP="${STALL_SLEEP:-60}"
CRASH_SLEEP="${CRASH_SLEEP:-30}"
IDENTICAL_STALL_PAUSE="${IDENTICAL_STALL_PAUSE:-10}"

LOCK_FILE="$DATADIR/.sync_supervisor.lock"
PID_FILE="$DATADIR/.sync_supervisor.pid"
STALL_JSON="$DATADIR/.sync_stall.json"
LOG="${SUPERVISOR_LOG:-$ROOT/sync_supervisor.log}"
BATCH_LOG="${BATCH_LOG:-$ROOT/sync_batch_run.log}"

mkdir -p "$DATADIR"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
  printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"
}

validated_height() {
  "$PY" -c "
import sqlite3, sys
from pathlib import Path
db = Path(sys.argv[1]) / 'pybitnode.db'
conn = sqlite3.connect(db)
row = conn.execute(
    \"SELECT validated_height FROM chain_state WHERE chain='testnet4' LIMIT 1\"
).fetchone()
conn.close()
print(int(row[0]) if row else 0)
" "$DATADIR"
}

write_stall_json() {
  local exit_code="$1"
  "$PY" -c "
import json, sqlite3, sys
from datetime import datetime, timezone
from pathlib import Path

datadir = Path(sys.argv[1])
stall_path = Path(sys.argv[2])
db = datadir / 'pybitnode.db'
validated = 0
height = None
error = None
ts = datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')
if db.is_file():
    conn = sqlite3.connect(db)
    row = conn.execute(
        \"SELECT validated_height FROM chain_state WHERE chain='testnet4' LIMIT 1\"
    ).fetchone()
    if row:
        validated = int(row[0])
        height = validated + 1
    ev = conn.execute(
        \"SELECT details_json FROM events WHERE message='Rejected invalid block' \"
        \"ORDER BY id DESC LIMIT 1\"
    ).fetchone()
    if ev and ev[0]:
        try:
            d = json.loads(ev[0])
            height = int(d.get('height', height or 0)) or height
            error = d.get('error')
        except json.JSONDecodeError:
            pass
    conn.close()
payload = {
    'height': height,
    'timestamp': ts,
    'validated_height': validated,
    'exit_code': int(sys.argv[3]),
    'error': error,
}
stall_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
print(json.dumps(payload))
" "$DATADIR" "$STALL_JSON" "$exit_code"
}

stall_pause_if_repeated() {
  local height="$1"
  local count_file="$DATADIR/.sync_stall_repeat_count"
  local last_file="$DATADIR/.sync_stall_last_height"
  local last="" count=0
  [[ -f "$last_file" ]] && last="$(<"$last_file")"
  if [[ "$last" == "$height" ]]; then
    count="$(<"$count_file" 2>/dev/null || echo 0)"
    count=$((count + 1))
  else
    count=1
  fi
  echo "$height" >"$last_file"
  echo "$count" >"$count_file"
  if [[ "$count" -ge "$IDENTICAL_STALL_PAUSE" ]]; then
    log "stall height=$height repeated ${count}x; sleeping 300s before retry"
    sleep 300
    return 0
  fi
  return 0
}

acquire_supervisor_lock() {
  exec 9>>"$LOCK_FILE"
  if ! "$PY" -c "import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)" 9<&9 2>/dev/null; then
    echo "$(ts) another sync_persistent_supervisor holds $LOCK_FILE — exiting" >>"$LOG"
    exit 2
  fi
}

acquire_supervisor_lock

echo $$ >"$PID_FILE"
log "supervisor start pid=$$ target=$TARGET datadir=$DATADIR"

trap 'log "supervisor received signal — exiting"; rm -f "$PID_FILE"; exit 0' INT TERM

while true; do
  vh="$(validated_height)"
  if [[ "$vh" -ge "$TARGET" ]]; then
    log "target reached validated_height=$vh (>= $TARGET)"
    rm -f "$PID_FILE"
    exit 0
  fi

  log "iteration start validated_height=$vh target=$TARGET"
  set +e
  ./scripts/sync_batch_loop.sh \
    --datadir "$DATADIR" \
    --target "$BATCH_TARGET" \
    --blocks-max "$BLOCKS_MAX" \
    --max-batches "$MAX_BATCHES" \
    --log "$BATCH_LOG" \
    --no-header-refresh
  rc=$?
  set -e

  vh_after="$(validated_height)"
  log "batch loop exit=$rc validated_height=$vh_after (was $vh)"

  case "$rc" in
    0)
      if [[ "$vh_after" -ge "$TARGET" ]]; then
        log "target reached after batch loop"
        rm -f "$PID_FILE"
        exit 0
      fi
      continue
      ;;
    4)
      log "max batches reached; restarting outer loop"
      continue
      ;;
    5)
      stall_info="$(write_stall_json "$rc")"
      log "STALL recorded: $stall_info"
      stall_h="$(echo "$stall_info" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('height') or 0)")"
      stall_pause_if_repeated "${stall_h:-0}"
      sleep "$STALL_SLEEP"
      continue
      ;;
    *)
      log "batch loop failed exit=$rc; sleep ${CRASH_SLEEP}s"
      sleep "$CRASH_SLEEP"
      continue
      ;;
  esac
done
