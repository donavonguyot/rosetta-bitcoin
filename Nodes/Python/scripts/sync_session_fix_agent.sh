#!/usr/bin/env bash
# sync_session_fix_agent.sh — in-session worker: restart detached supervisor, detect stuck sync, run repairs.
#
# Usage (foreground, from PythonNode):
#   ./scripts/sync_session_fix_agent.sh
#
# Env: TARGET (default 136343), MAX_FIX_CYCLES (3), MAX_ELAPSED_SEC (7200), POLL_SEC (180)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
TARGET="${TARGET:-136343}"
POLL_SEC="${POLL_SEC:-180}"
MAX_FIX_CYCLES="${MAX_FIX_CYCLES:-3}"
MAX_ELAPSED_SEC="${MAX_ELAPSED_SEC:-7200}"
STUCK_SEC="${STUCK_SEC:-900}"
SUPERVISOR_PID_FILE="$DATADIR/.sync_supervisor.pid"
SESSION_LOG="${SESSION_LOG:-$ROOT/sync_session_fix_agent.log}"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$SESSION_LOG"; }

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

supervisor_alive() {
  [[ -f "$SUPERVISOR_PID_FILE" ]] || return 1
  local pid
  pid="$(<"$SUPERVISOR_PID_FILE")"
  ps -p "$pid" -o args= 2>/dev/null | grep -q sync_persistent_supervisor
}

launch_supervisor_detached() {
  log "launching detached sync_persistent_supervisor"
  setsid nohup ./scripts/sync_persistent_supervisor.sh >>./sync_supervisor.log 2>&1 </dev/null &
  local pid=$!
  echo "$pid" >"$SUPERVISOR_PID_FILE"
  disown 2>/dev/null || true
  sleep 2
  log "supervisor pid=$pid parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
}

latest_reject_error() {
  "$PY" -c "
import json, sqlite3, sys
from pathlib import Path
db = Path(sys.argv[1]) / 'pybitnode.db'
if not db.is_file():
    sys.exit(0)
conn = sqlite3.connect(db)
ev = conn.execute(
    \"SELECT details_json FROM events WHERE message='Rejected invalid block' \"
    \"ORDER BY id DESC LIMIT 1\"
).fetchone()
conn.close()
if not ev or not ev[0]:
    sys.exit(0)
d = json.loads(ev[0])
print(d.get('error',''))
" "$DATADIR" 2>/dev/null || true
}

apply_fix_cycle() {
  local cycle="$1"
  log "fix cycle $cycle start"
  local err
  err="$(latest_reject_error)"

  if echo "$err" | grep -q 'Block size mismatch'; then
    log "diagnosis: corrupt block index — running repair_block_file_offsets.py"
    "$PY" scripts/repair_block_file_offsets.py --db "$DATADIR/pybitnode.db" --blocks-dir "$DATADIR/blocks" || return 1
    log "rebuild validated chain after offset repair"
    MAX_OUTBOUND_PEERS=1 SKIP_GETADDR=1 DATA_DIR="$DATADIR" \
      "$PY" -m pybitnode.sync_runner --datadir "$DATADIR" --connect-only --rebuild 2>&1 | tail -20 | tee -a "$SESSION_LOG" || true
    return 0
  fi

  if [[ -n "$err" ]]; then
    log "consensus stall (no auto-fix in shell): $err"
    return 0
  fi

  log "no reject event; checking offset repair for rebuild failures"
  "$PY" scripts/repair_block_file_offsets.py --db "$DATADIR/pybitnode.db" --blocks-dir "$DATADIR/blocks" 2>&1 | tee -a "$SESSION_LOG" || true
  return 0
}

start_ts=$(date +%s)
fix_cycles=0
last_vh=""
last_change_ts=$start_ts

log "session fix agent start target=$TARGET max_cycles=$MAX_FIX_CYCLES max_elapsed=${MAX_ELAPSED_SEC}s"

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  vh="$(validated_height)"

  if [[ "$vh" -ge "$TARGET" ]]; then
    log "target reached validated_height=$vh"
    exit 0
  fi
  if [[ "$elapsed" -ge "$MAX_ELAPSED_SEC" ]]; then
    log "max elapsed ${MAX_ELAPSED_SEC}s — stopping session agent (supervisor stays up)"
    exit 0
  fi
  if [[ "$fix_cycles" -ge "$MAX_FIX_CYCLES" ]]; then
    log "max fix cycles $MAX_FIX_CYCLES — stopping session agent (supervisor stays up)"
    exit 0
  fi

  if ! supervisor_alive; then
    log "supervisor not running — restarting detached"
    launch_supervisor_detached
  fi

  if [[ "$vh" != "$last_vh" ]]; then
    last_vh="$vh"
    last_change_ts=$now
    log "progress validated_height=$vh"
  elif [[ $((now - last_change_ts)) -ge "$STUCK_SEC" ]]; then
    if apply_fix_cycle "$((fix_cycles + 1))"; then
      fix_cycles=$((fix_cycles + 1))
      last_change_ts=$(date +%s)
    fi
  fi

  sleep "$POLL_SEC"
done
