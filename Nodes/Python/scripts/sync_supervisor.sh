#!/usr/bin/env bash
# Durable Python sync supervisor: local-Core subchunks, stop file, crash restart, chat-style ticks.
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data}"
DB="${DB:-$DATA_DIR/pybitnode.db}"
PEERS="${PEERS:-127.0.0.1:48333}"
LOG="${LOG:-sync_chunk_auto.log}"
CHUNK_TOTAL="${CHUNK_TOTAL:-15000}"
SUBCHUNK_SIZE="${SUBCHUNK_SIZE:-500}"
MAX_RESTARTS="${MAX_RESTARTS:-5}"
POLL_SEC="${POLL_SEC:-120}"

STOP_FILE="$DATA_DIR/.stop_sync"
SUPERVISOR_LOCK="$DATA_DIR/.pybitnode-supervisor.lock"
SUPERVISOR_LOCK_DIR="$DATA_DIR/.pybitnode-supervisor.lockdir"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"
}

db_status_json() {
  .venv/bin/pybitnode-db --db "$DB" 2>/dev/null || echo '{}'
}

read_field() {
  local json="$1" expr="$2"
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); $expr" 2>/dev/null || echo "?"
}

active_sync_writer() {
  ps -ax -o pid= -o command= | python3 -c '
import sys
rows = [
    line.strip()
    for line in sys.stdin
    if "pybitnode-sync" in line and " -c " not in line and "sync_supervisor.sh" not in line
]
print("\n".join(rows))
raise SystemExit(0 if not rows else 1)
'
}

preflight() {
  if ! active_sync_writer >/tmp/pybitnode-supervisor-writers.$$; then
    log_line "error: pybitnode-sync already running"
    cat /tmp/pybitnode-supervisor-writers.$$ | tee -a "$LOG"
    rm -f /tmp/pybitnode-supervisor-writers.$$
    exit 1
  fi
  rm -f /tmp/pybitnode-supervisor-writers.$$
}

stop_requested() {
  [[ -f "$STOP_FILE" ]]
}

handle_stop() {
  if stop_requested; then
    log_line "supervisor decision=stop reason=stop_file"
    rm -f "$STOP_FILE"
    exit 0
  fi
}

pybitnode_sync_running() {
  ps -ax -o command= | python3 -c '
import sys
running = any("pybitnode-sync" in line and " -c " not in line for line in sys.stdin)
raise SystemExit(0 if running else 1)
'
}

emit_tick() {
  local target="$1" last_h="$2"
  local json h s rem delta running_label
  json="$(db_status_json)"
  h="$(read_field "$json" "print(d.get('validated_height','?'))")"
  s="$(read_field "$json" "print(d.get('sync',{}).get('sync_status','?'))")"
  rem=0
  delta=0
  if [[ "$h" =~ ^[0-9]+$ ]]; then
    rem=$((target - h))
    if (( rem < 0 )); then rem=0; fi
  fi
  if [[ "$last_h" =~ ^[0-9]+$ ]] && [[ "$h" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_h))
  fi
  if pybitnode_sync_running; then
    running_label="pybitnode-sync running"
  else
    running_label="pybitnode-sync not running"
  fi
  log_line "2-min tick: validated_height $h (+$delta), $s, $running_label. $rem blocks left to target $target."
  EMIT_TICK_HEIGHT="$h"
}

run_subchunk() {
  local blocks_max="$1"
  log_line "supervisor starting subchunk BLOCKS_MAX=$blocks_max"
  set +e
  DATA_DIR="$DATA_DIR" DB="$DB" PEERS="$PEERS" BLOCKS_MAX="$blocks_max" \
    make python-node-sync-chunk >> "$LOG" 2>&1
  local code=$?
  set -e
  return "$code"
}

run_subchunk_monitored() {
  local blocks_max="$1" start_h="$2" target="$3"
  local tick_pid exit_code
  (
    local lh="$start_h"
    while true; do
      sleep "$POLL_SEC"
      emit_tick "$target" "$lh"
      lh="$EMIT_TICK_HEIGHT"
    done
  ) &
  tick_pid=$!
  set +e
  run_subchunk "$blocks_max"
  exit_code=$?
  set -e
  kill "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  return "$exit_code"
}

acquire_supervisor_lock() {
  mkdir -p "$DATA_DIR"
  if mkdir "$SUPERVISOR_LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$SUPERVISOR_LOCK"
    trap 'rm -rf "$SUPERVISOR_LOCK_DIR" "$SUPERVISOR_LOCK"' EXIT
    return 0
  fi
  local pid=""
  if [[ -f "$SUPERVISOR_LOCK" ]]; then
    pid="$(cat "$SUPERVISOR_LOCK" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    log_line "supervisor reclaim stale lock pid=$pid"
    rm -rf "$SUPERVISOR_LOCK_DIR" "$SUPERVISOR_LOCK"
    mkdir "$SUPERVISOR_LOCK_DIR"
    echo "$$" > "$SUPERVISOR_LOCK"
    trap 'rm -rf "$SUPERVISOR_LOCK_DIR" "$SUPERVISOR_LOCK"' EXIT
    return 0
  fi
  log_line "error: supervisor lock busy ($SUPERVISOR_LOCK)"
  exit 1
}

log_line "=== python supervisor start CHUNK_TOTAL=$CHUNK_TOTAL SUBCHUNK_SIZE=$SUBCHUNK_SIZE ==="
acquire_supervisor_lock
handle_stop
preflight

START_JSON="$(db_status_json)"
START_H="$(read_field "$START_JSON" "print(d.get('validated_height',0))")"
TARGET=$((START_H + CHUNK_TOTAL))
log_line "supervisor resume validated_height=$START_H target=$TARGET"

RESTARTS=0
LAST_RESTART_H="$START_H"

while true; do
  handle_stop
  preflight

  CUR_JSON="$(db_status_json)"
  CUR_H="$(read_field "$CUR_JSON" "print(d.get('validated_height',0))")"
  SYNC_STATUS="$(read_field "$CUR_JSON" "print(d.get('sync',{}).get('sync_status',''))")"
  CONNECTED_TOTAL=$((CUR_H - START_H))
  REMAINING=$((TARGET - CUR_H))
  if (( REMAINING <= 0 )); then
    log_line "supervisor decision=chunk_complete validated=$CUR_H"
    make python-node-status DATA_DIR="$DATA_DIR" DB="$DB" 2>&1 | tee -a "$LOG" || true
    make python-node-export-snapshots DATA_DIR="$DATA_DIR" DB="$DB" 2>&1 | tee -a "$LOG" || true
    exit 0
  fi

  SUB=$((REMAINING < SUBCHUNK_SIZE ? REMAINING : SUBCHUNK_SIZE))
  BEFORE_H="$CUR_H"
  set +e
  run_subchunk_monitored "$SUB" "$CUR_H" "$TARGET"
  EXIT_CODE=$?
  set -e
  emit_tick "$TARGET" "$BEFORE_H" >/dev/null

  AFTER_JSON="$(db_status_json)"
  AFTER_H="$(read_field "$AFTER_JSON" "print(d.get('validated_height',0))")"
  SYNC_STATUS="$(read_field "$AFTER_JSON" "print(d.get('sync',{}).get('sync_status',''))")"
  CONNECTED_TOTAL=$((AFTER_H - START_H))
  log_line "supervisor subchunk exit=$EXIT_CODE sync_status=$SYNC_STATUS validated=$AFTER_H connected_total=$CONNECTED_TOTAL/$CHUNK_TOTAL"

  if [[ "$SYNC_STATUS" == "blocks_blocked" ]]; then
    BLOCKER="$(read_field "$AFTER_JSON" "print(d.get('recent_events',[{}])[0].get('details_json','{}'))")"
    log_line "supervisor decision=exit_blocked blocker=$BLOCKER validated=$AFTER_H"
    exit 2
  fi

  if [[ "$EXIT_CODE" != "0" ]]; then
    if (( RESTARTS >= MAX_RESTARTS )); then
      log_line "supervisor decision=exit_stuck restarts=$RESTARTS validated=$AFTER_H"
      exit 3
    fi
    if [[ "$AFTER_H" == "$LAST_RESTART_H" ]] && (( RESTARTS > 0 )); then
      log_line "supervisor decision=exit_no_progress validated=$AFTER_H"
      exit 3
    fi
    RESTARTS=$((RESTARTS + 1))
    LAST_RESTART_H="$AFTER_H"
    log_line "supervisor decision=restart count=$RESTARTS/$MAX_RESTARTS reason=exit_$EXIT_CODE validated=$AFTER_H"
    sleep 2
    continue
  fi

  RESTARTS=0
  LAST_RESTART_H="$AFTER_H"
done
