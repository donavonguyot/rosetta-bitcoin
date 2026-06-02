#!/usr/bin/env bash
# sync_fix_agent_loop.sh — companion stall watcher (detached; does not mutate consensus code).
#
# Every 120s reads data/.sync_stall.json and latest "Rejected invalid block" event.
# If the same stall height appears 3+ times consecutively, appends FIX_NEEDED to sync_fix_needed.log
# for a human or Cursor agent to implement the missing rule.
#
# Launch detached:
#   setsid nohup ./scripts/sync_fix_agent_loop.sh >>./sync_fix_needed.log 2>&1 </dev/null &
#   echo $! > ./data/.sync_fix_agent.pid
#   disown

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
DATADIR="${DATADIR:-./data}"
INTERVAL="${FIX_INTERVAL:-120}"
STALL_JSON="$DATADIR/.sync_stall.json"
OUT_LOG="${FIX_NEEDED_LOG:-$ROOT/sync_fix_needed.log}"
PID_FILE="$DATADIR/.sync_fix_agent.pid"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

mkdir -p "$DATADIR"
echo $$ >"$PID_FILE"

last_height=""
repeat=0

while true; do
  info="$("$PY" -c "
import json, sqlite3, sys
from pathlib import Path

datadir = Path(sys.argv[1])
stall = datadir / '.sync_stall.json'
height = None
error = None
validated = None
if stall.is_file():
    try:
        d = json.loads(stall.read_text(encoding='utf-8'))
        height = d.get('height')
        error = d.get('error')
        validated = d.get('validated_height')
    except json.JSONDecodeError:
        pass
db = datadir / 'pybitnode.db'
if db.is_file():
    conn = sqlite3.connect(db)
    ev = conn.execute(
        \"SELECT details_json FROM events WHERE message='Rejected invalid block' \"
        \"ORDER BY id DESC LIMIT 1\"
    ).fetchone()
    if ev and ev[0]:
        try:
            d = json.loads(ev[0])
            height = height or d.get('height')
            error = error or d.get('error')
        except json.JSONDecodeError:
            pass
    if validated is None:
        row = conn.execute(
            \"SELECT validated_height FROM chain_state WHERE chain='testnet4' LIMIT 1\"
        ).fetchone()
        if row:
            validated = int(row[0])
    conn.close()
if height is None and validated is not None:
    height = validated + 1
print(json.dumps({'height': height, 'error': error, 'validated_height': validated}))
" "$DATADIR" 2>/dev/null || echo '{}')"

  height="$(echo "$info" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d.get('height') or '')")"
  error="$(echo "$info" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d.get('error') or '')")"

  if [[ -n "$height" ]]; then
    if [[ "$height" == "$last_height" ]]; then
      repeat=$((repeat + 1))
    else
      repeat=1
      last_height="$height"
    fi
    if [[ "$repeat" -ge 3 ]]; then
      msg="$(ts) FIX_NEEDED height=$height error=${error:-unknown} validated=$(echo "$info" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('validated_height',''))")"
      if ! grep -Fq "FIX_NEEDED height=$height " "$OUT_LOG" 2>/dev/null; then
        echo "$msg" | tee -a "$OUT_LOG"
      fi
    fi
  fi

  sleep "$INTERVAL"
done
