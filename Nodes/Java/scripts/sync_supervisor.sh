#!/usr/bin/env bash
# Durable sync supervisor: sub-chunks, crash restart, stop file, 2-min DbStatus ticks.
set -euo pipefail
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data-java}"
PEERS="${PEERS:-127.0.0.1:48333}"
SECP256K1_BACKEND="${SECP256K1_BACKEND:-bouncycastle}"
LOG="${LOG:-sync_chunk_auto.log}"
CHUNK_TOTAL="${CHUNK_TOTAL:-15000}"
SUBCHUNK_SIZE="${SUBCHUNK_SIZE:-500}"
MAX_RESTARTS="${MAX_RESTARTS:-5}"
PROGRESS_STALL_SEC="${PROGRESS_STALL_SEC:-900}"
POLL_SEC="${POLL_SEC:-120}"

STOP_FILE="$DATA_DIR/.stop_sync"
LOCK_FILE="$DATA_DIR/.jbitnode.lock"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
export MAVEN_OPTS="${MAVEN_OPTS:--Xmx4g -XX:+ExitOnOutOfMemoryError}"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"
}

db_status_json() {
  DATA_DIR="$DATA_DIR" mvn -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.DbStatus 2>/dev/null || echo '{}'
}

read_field() {
  local json="$1" expr="$2"
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); $expr" 2>/dev/null || echo "?"
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

reclaim_stale_lock() {
  if [[ ! -f "$LOCK_FILE" ]]; then
    return 0
  fi
  local pid
  pid="$(grep -E '^pid=' "$LOCK_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  if [[ -z "$pid" ]]; then
    if ! lsof "$LOCK_FILE" >/dev/null 2>&1; then
      log_line "supervisor reclaim stale lock (no pid metadata)"
      rm -f "$LOCK_FILE"
    fi
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    log_line "supervisor reclaim stale lock pid=$pid"
    rm -f "$LOCK_FILE"
  fi
}

preflight() {
  if pgrep -f '[c]om\.jbitnode\.cli\.SyncLocalCore' >/dev/null 2>&1; then
    log_line "error: SyncLocalCore already running"
    exit 1
  fi
  reclaim_stale_lock
}

sync_local_core_running() {
  pgrep -f '[c]om\.jbitnode\.cli\.SyncLocalCore' >/dev/null 2>&1
}

emit_tick() {
  local target="$1" last_h="$2"
  local json h s rem delta running
  json="$(db_status_json)"
  h="$(read_field "$json" "print(d.get('validated_height','?'))")"
  s="$(read_field "$json" "print(d.get('sync',{}).get('sync_status','?'))")"
  if sync_local_core_running; then running=1; else running=0; fi
  rem=$((target - h))
  delta=0
  if [[ "$last_h" =~ ^[0-9]+$ ]] && [[ "$h" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_h))
  fi
  log_line "AGENT_LOOP_TICK_chatreport {\"ts\":\"$(date -u +%H:%M:%SZ)\",\"validated_height\":$h,\"sync_status\":\"$s\",\"remaining\":$rem,\"delta_since_last\":$delta,\"process_running\":$running,\"target\":$target,\"chunk_total\":$CHUNK_TOTAL}"
  echo "$h"
}

run_subchunk() {
  local blocks_max="$1"
  log_line "supervisor starting subchunk BLOCKS_MAX=$blocks_max"
  set +e
  DATA_DIR="$DATA_DIR" PEERS="$PEERS" BLOCKS_MAX="$blocks_max" PAR_SCRIPT_VERIFY=1 \
    SECP256K1_BACKEND="$SECP256K1_BACKEND" \
    mvn -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore \
    >> "$LOG" 2>&1
  local code=$?
  set -e
  return "$code"
}

run_subchunk_monitored() {
  local blocks_max="$1"
  local start_h="$2"
  local target="$3"
  local tick_pid
  local last_progress
  last_progress=$(date +%s)
  (
    local lh="$start_h"
    while true; do
      sleep "$POLL_SEC"
      lh="$(emit_tick "$target" "$lh")"
      if [[ "$lh" =~ ^[0-9]+$ ]] && [[ "$lh" -gt "$start_h" ]]; then
        last_progress=$(date +%s)
        start_h="$lh"
      fi
    done
  ) &
  tick_pid=$!
  set +e
  run_subchunk "$blocks_max"
  local exit_code=$?
  set -e
  kill "$tick_pid" 2>/dev/null || true
  wait "$tick_pid" 2>/dev/null || true
  # Successful sub-chunks can run longer than PROGRESS_STALL_SEC; only stall-check failures.
  if [[ "$exit_code" == "0" ]]; then
    return 0
  fi
  if (( $(date +%s) - last_progress >= PROGRESS_STALL_SEC )); then
    log_line "supervisor progress stall detected after subchunk validated=$start_h"
    return 1
  fi
  return "$exit_code"
}

log_line "=== supervisor start CHUNK_TOTAL=$CHUNK_TOTAL SUBCHUNK_SIZE=$SUBCHUNK_SIZE ==="
handle_stop
preflight

START_JSON="$(db_status_json)"
START_H="$(read_field "$START_JSON" "print(d.get('validated_height',0))")"
TARGET=$((START_H + CHUNK_TOTAL))
log_line "supervisor resume validated_height=$START_H target=$TARGET"

CONNECTED_TOTAL=0
RESTARTS=0
LAST_RESTART_H="$START_H"

while (( CONNECTED_TOTAL < CHUNK_TOTAL )); do
  handle_stop
  preflight

  CUR_JSON="$(db_status_json)"
  CUR_H="$(read_field "$CUR_JSON" "print(d.get('validated_height',0))")"
  REMAINING=$((CHUNK_TOTAL - CONNECTED_TOTAL))
  SUB=$((REMAINING < SUBCHUNK_SIZE ? REMAINING : SUBCHUNK_SIZE))
  if (( SUB <= 0 )); then
    break
  fi

  BEFORE_H="$CUR_H"
  set +e
  run_subchunk_monitored "$SUB" "$CUR_H" "$TARGET"
  EXIT_CODE=$?
  set -e
  emit_tick "$TARGET" "$BEFORE_H" >/dev/null

  AFTER_JSON="$(db_status_json)"
  SYNC_STATUS="$(read_field "$AFTER_JSON" "print(d.get('sync',{}).get('sync_status',''))")"
  AFTER_H="$(read_field "$AFTER_JSON" "print(d.get('validated_height',0))")"
  CONNECTED=$((AFTER_H - START_H))
  CONNECTED_TOTAL=$CONNECTED

  log_line "supervisor subchunk exit=$EXIT_CODE sync_status=$SYNC_STATUS validated=$AFTER_H connected_total=$CONNECTED_TOTAL/$CHUNK_TOTAL"

  if [[ "$SYNC_STATUS" == "blocks_blocked" ]] || [[ "$EXIT_CODE" == "4" ]]; then
    BLOCKER_H="$(read_field "$AFTER_JSON" "import json; b=d.get('current_blocker') or {}; dj=b.get('details_json'); print(json.loads(dj).get('height','?') if dj else '?')")"
    log_line "supervisor decision=exit_blocked blocker_height=$BLOCKER_H validated=$AFTER_H"
    exit 2
  fi

  if [[ "$SYNC_STATUS" == "blocks_idle" ]] && (( CONNECTED_TOTAL >= CHUNK_TOTAL )); then
    log_line "supervisor decision=chunk_complete validated=$AFTER_H"
    make java-node-status 2>&1 | tee -a "$LOG" || true
    make java-node-export-snapshots 2>&1 | tee -a "$LOG" || true
    exit 0
  fi

  if [[ "$SYNC_STATUS" == "blocks_stalled" ]] || [[ "$EXIT_CODE" != "0" ]]; then
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
    log_line "supervisor decision=restart count=$RESTARTS/$MAX_RESTARTS reason=exit_$EXIT_CODE status=$SYNC_STATUS validated=$AFTER_H"
    reclaim_stale_lock
    sleep 2
    continue
  fi

  # Normal subchunk completion — continue until CHUNK_TOTAL
  RESTARTS=0
  LAST_RESTART_H="$AFTER_H"
done

log_line "supervisor decision=chunk_complete validated=$AFTER_H"
make java-node-status 2>&1 | tee -a "$LOG" || true
make java-node-export-snapshots 2>&1 | tee -a "$LOG" || true
exit 0
