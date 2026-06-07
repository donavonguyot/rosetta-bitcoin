#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
if [[ -f "$REFERENCE_TOPOLOGY_ENV" ]]; then
  # shellcheck source=/dev/null
  . "$REFERENCE_TOPOLOGY_ENV"
fi
VOLUME="${DOCKER_PROOF_VOLUME:-csbitnode_sync_data}"
CONTAINER_NAME="${CONTAINER_NAME:-csbitnode-sync-supervisor-run}"
POLL_SEC="${POLL_SEC:-120}"
CHECK_SEC="${CHECK_SEC:-5}"
HEADERS_MAX="${HEADERS_MAX:-10000}"
HEADER_BATCHES_MAX="${HEADER_BATCHES_MAX:-50}"
BLOCKS_MAX="${BLOCKS_MAX:-500}"
PEERS="${PEERS:-${REFERENCE_P2P_PEER:-127.0.0.1:48333}}"
PEER_MODE="${PEER_MODE:-local_reference}"
SUPERVISOR_ONCE="${SUPERVISOR_ONCE:-0}"
STOP_FILE=".csbitnode_supervisor_stop"
RESUME_FILE=".csbitnode_supervisor_resume"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

compose() {
  docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml "$@"
}

volume_file_exists() {
  local file="$1"
  docker run --rm -v "$VOLUME":/data alpine:3.20 test -f "/data/$file" >/dev/null 2>&1
}

remove_volume_file() {
  local file="$1"
  docker run --rm -v "$VOLUME":/data alpine:3.20 rm -f "/data/$file" >/dev/null 2>&1 || true
}

source_signature() {
  python3 - <<'PY'
import hashlib
import pathlib

root = pathlib.Path(".")
paths = [
    *root.glob("src/**/*.cs"),
    *root.glob("tests/**/*.cs"),
    root / "src/CsBitNode/CsBitNode.csproj",
    root / "Dockerfile",
    root / "docker-compose.yml",
]
h = hashlib.sha256()
for path in sorted({p for p in paths if p.exists()}):
    h.update(str(path).encode())
    h.update(b"\0")
    h.update(path.read_bytes())
    h.update(b"\0")
print(h.hexdigest())
PY
}

build_image() {
  log_line "supervisor build image=csbitnode-sync-proof"
  compose build csbitnode-sync-proof
}

status_json() {
  DOCKER_PROOF_VOLUME="$VOLUME" PEERS="$PEERS" SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
    compose run --rm --no-deps csbitnode-sync-proof status 2>/dev/null || echo '{}'
}

field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null || echo "?"
}

json_number_or_null() {
  local value="$1"
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$value"
  else
    echo "null"
  fi
}

emit_benchmark_tick() {
  local json="$1" last_height="$2" phase="$3" process_running="$4"
  printf '%s\n' "$json" | \
    TARGET_BLOCK_HEIGHT="${TARGET_BLOCK_HEIGHT:-$HEADERS_MAX}" BENCHMARK_GATE="${BENCHMARK_GATE:-supervisor}" \
    BENCHMARK_STARTED_MS="$STARTED_MS" BENCHMARK_LAST_HEIGHT="$last_height" \
    BENCHMARK_PHASE="$phase" BENCHMARK_PROCESS_RUNNING="$process_running" POLL_SEC="$POLL_SEC" \
    python3 scripts/emit_benchmark_telemetry_tick.py
}

emit_tick() {
  local phase="$1" last_height="$2"
  local json h header stored status blocker delta process_running
  local h_json header_json stored_json delta_json
  json="$(status_json)"
  h="$(echo "$json" | field "print(d.get('validated_height','?'))")"
  header="$(echo "$json" | field "print(d.get('header_height','?'))")"
  stored="$(echo "$json" | field "print(d.get('stored_block_height','?'))")"
  status="$(echo "$json" | field "print(d.get('sync_status','?'))")"
  blocker="$(echo "$json" | field "import json; b=d.get('current_blocker'); print(json.dumps(b) if b else 'null')")"
  process_running="$(docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" && echo 1 || echo 0)"
  delta=0
  if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$last_height" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_height))
  fi
  h_json="$(json_number_or_null "$h")"
  header_json="$(json_number_or_null "$header")"
  stored_json="$(json_number_or_null "$stored")"
  delta_json="$(json_number_or_null "$delta")"
  log_line "AGENT_LOOP_TICK_chatreport {\"phase\":\"$phase\",\"runtime_surface\":\"docker\",\"peer_mode\":\"$PEER_MODE\",\"peer\":\"$PEERS\",\"validated_height\":$h_json,\"header_height\":$header_json,\"stored_block_height\":$stored_json,\"sync_status\":\"$status\",\"delta_since_last\":$delta_json,\"process_running\":$process_running,\"current_blocker\":$blocker}"
  log_line "$(emit_benchmark_tick "$json" "$last_height" "$phase" "$process_running")"
  echo "$h"
}

run_chunk() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  DOCKER_PROOF_VOLUME="$VOLUME" PEERS="$PEERS" SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
    HEADERS_MAX="$HEADERS_MAX" HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" BLOCKS_MAX="$BLOCKS_MAX" \
    compose run -d --name "$CONTAINER_NAME" csbitnode-sync-proof >/dev/null
}

wait_for_chunk() {
  local last_height="$1"
  local last_report now
  last_report="$(date +%s)"
  while docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; do
    sleep "$CHECK_SEC"
    if volume_file_exists "$STOP_FILE"; then
      log_line "supervisor decision=stop reason=stop_file"
      docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
      remove_volume_file "$STOP_FILE"
      exit 0
    fi
    now="$(date +%s)"
    if (( now - last_report >= POLL_SEC )); then
      last_height="$(emit_tick running "$last_height")"
      last_report="$now"
    fi
  done
}

pause_until_fix() {
  local last_sig="$1" last_height="$2"
  local last_report now current_sig
  last_report="$(date +%s)"
  log_line "supervisor decision=pause waiting_for=code_fix_or_resume volume=$VOLUME"
  while true; do
    sleep "$CHECK_SEC"
    if volume_file_exists "$STOP_FILE"; then
      log_line "supervisor decision=stop reason=stop_file"
      remove_volume_file "$STOP_FILE"
      exit 0
    fi
    now="$(date +%s)"
    if (( now - last_report >= POLL_SEC )); then
      last_height="$(emit_tick paused "$last_height")"
      last_report="$now"
    fi
    current_sig="$(source_signature)"
    if [[ "$current_sig" != "$last_sig" ]] || volume_file_exists "$RESUME_FILE"; then
      remove_volume_file "$RESUME_FILE"
      build_image
      SOURCE_SIG="$current_sig"
      return 0
    fi
  done
}

if [[ "${DOCKER_REBUILD:-0}" == "1" ]]; then
  build_image
else
  log_line "supervisor build skipped reason=warm_image_reuse rebuild_with=DOCKER_REBUILD=1"
fi
STARTED_MS="$(now_ms)"
SOURCE_SIG="$(source_signature)"
last_height="$(emit_tick starting 0)"
log_line "supervisor start volume=$VOLUME headers_max=$HEADERS_MAX header_batches_max=$HEADER_BATCHES_MAX blocks_max=$BLOCKS_MAX poll_sec=$POLL_SEC check_sec=$CHECK_SEC"

if [[ "$SUPERVISOR_ONCE" == "1" && "$BLOCKS_MAX" == "0" ]]; then
  log_line "supervisor decision=smoke_once reason=blocks_max_zero"
  exit 0
fi

while true; do
  if volume_file_exists "$STOP_FILE"; then
    log_line "supervisor decision=stop reason=stop_file"
    remove_volume_file "$STOP_FILE"
    exit 0
  fi

  run_chunk
  wait_for_chunk "$last_height"
  exit_code="$(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo 125)"
  docker logs "$CONTAINER_NAME" || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  new_height="$(emit_tick chunk_exit "$last_height")"
  log_line "supervisor chunk_exit exit_code=$exit_code previous_validated=$last_height current_validated=$new_height"

  if [[ "$exit_code" != "0" ]]; then
    pause_until_fix "$SOURCE_SIG" "$new_height"
  fi
  if [[ "$SUPERVISOR_ONCE" == "1" ]]; then
    exit 0
  fi
  last_height="$new_height"
done
