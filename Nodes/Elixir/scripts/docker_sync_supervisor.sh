#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DOCKER_COMPOSE=${DOCKER_COMPOSE:-"docker compose -f docker/docker-compose.yml"}
DOCKER_PROOF_VOLUME=${DOCKER_PROOF_VOLUME:-exbitnode_sync_data}
CONTAINER_NAME=${CONTAINER_NAME:-exbitnode-sync-supervisor-run}
POLL_SEC=${POLL_SEC:-120}
CHECK_SEC=${CHECK_SEC:-5}
HEADERS_MAX=${HEADERS_MAX:-10000}
HEADER_BATCHES_MAX=${HEADER_BATCHES_MAX:-50}
BLOCKS_MAX=${BLOCKS_MAX:-500}
PEERS=${PEERS:-bitcoin-core-testnet4:48333}
BLOCK_PREFETCH_DEPTH=${BLOCK_PREFETCH_DEPTH:-0}
SYNC_TIMING=${SYNC_TIMING:-1}
SYNC_SNAPSHOT_SEC=${SYNC_SNAPSHOT_SEC:-5}
SYNC_SNAPSHOT_BLOCKS=${SYNC_SNAPSHOT_BLOCKS:-0}
SCRIPT_VERIFY_TIMEOUT_MS=${SCRIPT_VERIFY_TIMEOUT_MS:-300000}
PAR_SCRIPT_VERIFY=${PAR_SCRIPT_VERIFY:-1}
PAR_SCRIPT_THREADS=${PAR_SCRIPT_THREADS:-4}
PAR_SCRIPT_MIN_INPUTS=${PAR_SCRIPT_MIN_INPUTS:-2}
RUNTIME_SURFACE=${RUNTIME_SURFACE:-docker_supervisor}
SUPERVISOR_ONCE=${SUPERVISOR_ONCE:-0}
STOP_FILE=${STOP_FILE:-.exbitnode_supervisor_stop}
RESUME_FILE=${RESUME_FILE:-.exbitnode_supervisor_resume}

read -r -a DOCKER_COMPOSE_CMD <<< "$DOCKER_COMPOSE"

log_line() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

volume_test_file() {
  docker run --rm -v "${DOCKER_PROOF_VOLUME}:/data" alpine:3.20 \
    sh -c "test -f /data/$1" >/dev/null 2>&1
}

volume_rm_file() {
  docker run --rm -v "${DOCKER_PROOF_VOLUME}:/data" alpine:3.20 \
    sh -c "rm -f /data/$1" >/dev/null 2>&1 || true
}

volume_write_file() {
  docker run --rm -v "${DOCKER_PROOF_VOLUME}:/data" alpine:3.20 \
    sh -c "printf '%s\n' \"$2\" > /data/$1" >/dev/null 2>&1 || true
}

source_signature() {
  {
    find lib c_src test docker scripts -type f 2>/dev/null | sort | xargs shasum 2>/dev/null || true
    shasum mix.exs Makefile 2>/dev/null || true
  } | shasum | awk '{print $1}'
}

build_image() {
  log_line "building Elixir Docker sync image"
  DOCKER_PROOF_VOLUME="$DOCKER_PROOF_VOLUME" "${DOCKER_COMPOSE_CMD[@]}" build exbitnode-sync-proof
}

status_json() {
  local raw
  set +e
  raw="$(
    DOCKER_PROOF_VOLUME="$DOCKER_PROOF_VOLUME" \
    RUNTIME_SURFACE="$RUNTIME_SURFACE" \
    PEERS="$PEERS" \
    BLOCK_PREFETCH_DEPTH="$BLOCK_PREFETCH_DEPTH" \
    SYNC_TIMING="$SYNC_TIMING" \
    SYNC_SNAPSHOT_SEC="$SYNC_SNAPSHOT_SEC" \
    SYNC_SNAPSHOT_BLOCKS="$SYNC_SNAPSHOT_BLOCKS" \
    SCRIPT_VERIFY_TIMEOUT_MS="$SCRIPT_VERIFY_TIMEOUT_MS" \
      "${DOCKER_COMPOSE_CMD[@]}" run --rm --no-deps exbitnode-sync-proof mix node.status 2>/dev/null
  )"
  set -e

  if [[ -z "$raw" ]]; then
    echo '{}'
  else
    printf '%s\n' "$raw"
  fi
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"
}

container_exit_code() {
  docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo 127
}

emit_tick() {
  local phase="$1"
  local last_height="${2:--1}"
  local process_running="false"
  if container_running; then
    process_running="true"
  fi

  local raw_status
  raw_status="$(status_json)"

  local tick
  tick="$(
    STATUS_JSON="$raw_status" \
    PHASE="$phase" \
    PROCESS_RUNNING="$process_running" \
    LAST_HEIGHT="$last_height" \
    PEERS="$PEERS" \
    python3 - <<'PY'
import json
import os

raw = os.environ.get("STATUS_JSON", "")
start = raw.find("{")
end = raw.rfind("}")
try:
    status = json.loads(raw[start:end + 1]) if start >= 0 and end >= start else {}
except Exception:
    status = {}

def integer(value, default=None):
    if value is None:
        return default
    try:
        return int(value)
    except Exception:
        return default

validated = integer(status.get("validated_height"), None)
last = integer(os.environ.get("LAST_HEIGHT"), None)
delta = None
if validated is not None and last is not None and last >= 0:
    delta = validated - last

tick = {
    "phase": os.environ.get("PHASE", "unknown"),
    "runtime_surface": status.get("runtime_surface") or "docker_supervisor",
    "peer_mode": "local_reference",
    "peer": status.get("peer_source") or os.environ.get("PEERS"),
    "validated_height": validated,
    "header_height": integer(status.get("header_height"), None),
    "stored_block_height": integer(status.get("stored_block_height"), None),
    "sync_status": status.get("sync_status") or status.get("runtime_status") or "unknown",
    "delta_since_last": delta,
    "process_running": os.environ.get("PROCESS_RUNNING") == "true",
    "current_blocker": status.get("current_blocker"),
}
print(json.dumps(tick, sort_keys=True, separators=(",", ":")))
PY
  )"
  log_line "AGENT_LOOP_TICK_chatreport ${tick}"
  printf '%s\n' "$raw_status" | \
    TARGET_BLOCK_HEIGHT="${TARGET_BLOCK_HEIGHT:-$HEADERS_MAX}" \
    BENCHMARK_GATE="${BENCHMARK_GATE:-supervisor}" \
    BENCHMARK_STARTED_MS="$STARTED_MS" \
    BENCHMARK_LAST_HEIGHT="$last_height" \
    BENCHMARK_PHASE="$phase" \
    BENCHMARK_PROCESS_RUNNING="$process_running" \
    POLL_SEC="$POLL_SEC" \
    python3 scripts/emit_benchmark_telemetry_tick.py | while IFS= read -r line; do
      log_line "$line"
    done

  TICK_JSON="$tick" python3 - <<'PY'
import json
import os
import sys
try:
    print(json.loads(os.environ.get("TICK_JSON", "{}")).get("validated_height") or -1)
except Exception:
    print(-1)
PY
}

start_chunk() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  log_line "starting detached Elixir sync chunk container=${CONTAINER_NAME} blocks_max=${BLOCKS_MAX} headers_max=${HEADERS_MAX} peers=${PEERS}"
  DOCKER_PROOF_VOLUME="$DOCKER_PROOF_VOLUME" \
  RUNTIME_SURFACE="$RUNTIME_SURFACE" \
  PEERS="$PEERS" \
  HEADERS_MAX="$HEADERS_MAX" \
  HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" \
  BLOCKS_MAX="$BLOCKS_MAX" \
  BLOCK_PREFETCH_DEPTH="$BLOCK_PREFETCH_DEPTH" \
  SYNC_TIMING="$SYNC_TIMING" \
  SYNC_SNAPSHOT_SEC="$SYNC_SNAPSHOT_SEC" \
  SYNC_SNAPSHOT_BLOCKS="$SYNC_SNAPSHOT_BLOCKS" \
  SCRIPT_VERIFY_TIMEOUT_MS="$SCRIPT_VERIFY_TIMEOUT_MS" \
  PAR_SCRIPT_VERIFY="$PAR_SCRIPT_VERIFY" \
  PAR_SCRIPT_THREADS="$PAR_SCRIPT_THREADS" \
  PAR_SCRIPT_MIN_INPUTS="$PAR_SCRIPT_MIN_INPUTS" \
    "${DOCKER_COMPOSE_CMD[@]}" run -d --name "$CONTAINER_NAME" --no-deps exbitnode-sync-proof mix sync.local >/dev/null
}

wait_for_chunk() {
  local last_tick_epoch
  last_tick_epoch="$(date +%s)"
  local last_height="$1"

  while container_running; do
    if [[ -f "$STOP_FILE" ]] || volume_test_file ".exbitnode_supervisor_stop"; then
      log_line "stop marker detected; stopping active sync container"
      docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
      volume_rm_file ".exbitnode_supervisor_stop"
      rm -f "$STOP_FILE"
      emit_tick "stopped" "$last_height" >/dev/null
      return 0
    fi

    sleep "$CHECK_SEC"
    local now
    now="$(date +%s)"
    if (( now - last_tick_epoch >= POLL_SEC )); then
      last_height="$(emit_tick "syncing" "$last_height")"
      last_tick_epoch="$now"
    fi
  done
}

pause_needed() {
  local exit_code="$1"
  local raw_status="$2"

  EXIT_CODE="$exit_code" STATUS_JSON="$raw_status" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("STATUS_JSON", "")
start = raw.find("{")
end = raw.rfind("}")
try:
    status = json.loads(raw[start:end + 1]) if start >= 0 and end >= start else {}
except Exception:
    status = {}

exit_code = int(os.environ.get("EXIT_CODE", "127"))
sync_status = status.get("sync_status") or status.get("runtime_status")
should_pause = (
    exit_code != 0
    or bool(status.get("current_blocker"))
    or bool(status.get("last_error"))
    or sync_status in {"blocked", "failed", "error"}
)
sys.exit(0 if should_pause else 1)
PY
}

pause_until_resume_or_change() {
  local original_signature="$1"
  local last_height="$2"

  log_line "supervisor paused; waiting for resume marker, stop marker, or source change"
  while true; do
    if [[ -f "$STOP_FILE" ]] || volume_test_file ".exbitnode_supervisor_stop"; then
      volume_rm_file ".exbitnode_supervisor_stop"
      rm -f "$STOP_FILE"
      emit_tick "stopped" "$last_height" >/dev/null
      exit 0
    fi

    if [[ -f "$RESUME_FILE" ]] || volume_test_file ".exbitnode_supervisor_resume"; then
      volume_rm_file ".exbitnode_supervisor_resume"
      rm -f "$RESUME_FILE"
      log_line "resume marker detected"
      return 0
    fi

    local current_signature
    current_signature="$(source_signature)"
    if [[ "$current_signature" != "$original_signature" ]]; then
      log_line "source change detected; rebuilding before resume"
      build_image
      return 0
    fi

    sleep "$POLL_SEC"
    emit_tick "paused" "$last_height" >/dev/null
  done
}

build_image
STARTED_MS="$(now_ms)"
source_sig="$(source_signature)"
last_height="$(emit_tick "starting" -1)"

while true; do
  if [[ -f "$STOP_FILE" ]] || volume_test_file ".exbitnode_supervisor_stop"; then
    volume_rm_file ".exbitnode_supervisor_stop"
    rm -f "$STOP_FILE"
    emit_tick "stopped" "$last_height" >/dev/null
    exit 0
  fi

  start_chunk
  wait_for_chunk "$last_height"

  exit_code="$(container_exit_code)"
  volume_write_file ".exbitnode_last_sync_exit" "$exit_code"
  log_line "sync chunk exited code=${exit_code}"
  docker logs "$CONTAINER_NAME" >&2 || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  last_height="$(emit_tick "chunk_exit" "$last_height")"
  raw_status="$(status_json)"

  if pause_needed "$exit_code" "$raw_status"; then
    if [[ "$SUPERVISOR_ONCE" == "1" ]]; then
      emit_tick "paused" "$last_height" >/dev/null
      exit 0
    fi

    pause_until_resume_or_change "$source_sig" "$last_height"
    source_sig="$(source_signature)"
  fi

  if [[ "$SUPERVISOR_ONCE" == "1" ]]; then
    exit "$exit_code"
  fi
done
