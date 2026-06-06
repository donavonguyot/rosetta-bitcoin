#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
# shellcheck source=/dev/null
. "$REFERENCE_TOPOLOGY_ENV"
DOCKER_COMPOSE=(docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml)

VOLUME="${DOCKER_SYNC_VOLUME:-tsbitnode_sync_data}"
CONTAINER_NAME="${CONTAINER_NAME:-tsbitnode-sync-supervisor-run}"
POLL_SEC="${POLL_SEC:-120}"
CHECK_SEC="${CHECK_SEC:-5}"
STOP_FILE=".tsbitnode_supervisor_stop"
RESUME_FILE=".tsbitnode_supervisor_resume"
PEER="${PEERS:-${REFERENCE_P2P_PEER:?REFERENCE_P2P_PEER missing}}"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

volume_file_exists() {
  docker run --rm -v "$VOLUME":/data alpine:3.20 test -f "/data/$1" >/dev/null 2>&1
}

remove_volume_file() {
  docker run --rm -v "$VOLUME":/data alpine:3.20 rm -f "/data/$1" >/dev/null 2>&1 || true
}

status_json() {
  DOCKER_SYNC_VOLUME="$VOLUME" SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
    "${DOCKER_COMPOSE[@]}" run --rm --no-deps tsbitnode-sync-status 2>/dev/null || echo '{}'
}

json_field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null || echo "0"
}

emit_tick() {
  local phase="$1" last_height="$2"
  local json h header stored status blocker delta running
  json="$(status_json)"
  h="$(echo "$json" | json_field "print(d.get('validated_height',0))")"
  header="$(echo "$json" | json_field "print(d.get('header_height',0))")"
  stored="$(echo "$json" | json_field "print(d.get('stored_block_height',0))")"
  status="$(echo "$json" | json_field "print(d.get('sync_status','starting'))")"
  blocker="$(echo "$json" | json_field "import json; print(json.dumps(d.get('current_blocker')) if d.get('current_blocker') else 'null')")"
  running="$(docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" && echo true || echo false)"
  delta=0
  if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$last_height" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_height))
  fi
  log_line "AGENT_LOOP_TICK_chatreport {\"phase\":\"$phase\",\"runtime_surface\":\"docker\",\"peer_mode\":\"local_reference\",\"peer\":\"$PEER\",\"validated_height\":$h,\"header_height\":$header,\"stored_block_height\":$stored,\"sync_status\":\"$status\",\"delta_since_last\":$delta,\"process_running\":$running,\"current_blocker\":$blocker}"
  echo "$h"
}

run_chunk() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  DOCKER_PROOF_VOLUME="$VOLUME" SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
    "${DOCKER_COMPOSE[@]}" run -d --name "$CONTAINER_NAME" tsbitnode-sync-proof >/dev/null
}

wait_for_chunk() {
  local last_height="$1"
  local last_report now
  last_report="$(date +%s)"
  while docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; do
    sleep "$CHECK_SEC"
    if volume_file_exists "$STOP_FILE"; then
      log_line "supervisor decision=stop reason=stop_file"
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

if [[ "${DOCKER_REBUILD:-0}" == "1" ]]; then
  "${DOCKER_COMPOSE[@]}" build tsbitnode-sync-proof tsbitnode-sync-status >/dev/null
else
  log_line "supervisor build skipped reason=warm_image_reuse rebuild_with=DOCKER_REBUILD=1"
fi
last_height="$(emit_tick starting 0)"
log_line "supervisor start volume=$VOLUME poll_sec=$POLL_SEC check_sec=$CHECK_SEC"

if [[ "${SUPERVISOR_ONCE:-0}" == "1" ]]; then
  emit_tick smoke "$last_height" >/dev/null
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
    log_line "supervisor decision=pause waiting_for=resume_marker"
    while ! volume_file_exists "$RESUME_FILE"; do
      sleep "$CHECK_SEC"
      if volume_file_exists "$STOP_FILE"; then
        remove_volume_file "$STOP_FILE"
        exit 0
      fi
    done
    remove_volume_file "$RESUME_FILE"
  fi
  last_height="$new_height"
done
