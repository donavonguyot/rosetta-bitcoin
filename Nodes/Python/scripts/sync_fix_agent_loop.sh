#!/usr/bin/env bash
# Native-state stall watcher. Full replay/blocker rediscovery is out of scope here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
STATE_PATH="${STATE_PATH:-$DATADIR/chainstate-rocksdb}"
INTERVAL="${FIX_INTERVAL:-120}"
OUT_LOG="${FIX_NEEDED_LOG:-$ROOT/sync_fix_needed.log}"
PID_FILE="$DATADIR/.sync_fix_agent.pid"

mkdir -p "$DATADIR"
echo $$ >"$PID_FILE"

last_height=""
repeat=0

while true; do
  info="$("$PY" scripts/cursor_sync_monitor.py --state-path "$STATE_PATH" --once 2>/dev/null | sed 's/^AGENT_LOOP_TICK_pybitnode_sync //' || echo '{}')"
  height="$(echo "$info" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print((d.get('validated_height') or 0)+1)")"
  blocker="$(echo "$info" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d.get('current_blocker') or '')")"
  if [[ "$height" == "$last_height" ]]; then
    repeat=$((repeat + 1))
  else
    repeat=1
    last_height="$height"
  fi
  if [[ "$repeat" -ge 3 && -n "$blocker" ]]; then
    msg="$(date -u '+%Y-%m-%dT%H:%M:%SZ') FIX_NEEDED height=$height error=$blocker"
    if ! grep -Fq "FIX_NEEDED height=$height " "$OUT_LOG" 2>/dev/null; then
      echo "$msg" | tee -a "$OUT_LOG"
    fi
  fi
  sleep "$INTERVAL"
done
