#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
DOCKER_COMPOSE=(docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml)
POLL_SEC="${POLL_SEC:-120}"
CONTAINER_NAME="${CONTAINER_NAME:-csbitnode-sync-proof-run}"
STATUS_FILE="${STATUS_FILE:-.docker-csharp-proof-status.json}"
EXIT_FILE="${EXIT_FILE:-.docker-csharp-proof-exit}"
RUN_FILE="${RUN_FILE:-.docker-csharp-proof-run.json}"
PROGRESS_STATE_FILE="${PROGRESS_STATE_FILE:-.docker-csharp-proof-progress.state}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-250}"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

status_command_json() {
  DOCKER_PROOF_VOLUME="${DOCKER_PROOF_VOLUME:-csbitnode_proof_data}" \
  SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
  "${DOCKER_COMPOSE[@]}" run --rm --no-deps csbitnode-sync-proof status 2>/dev/null || echo '{}'
}

progress_json() {
  docker logs "$CONTAINER_NAME" 2>/dev/null | python3 -c 'import json, sys
latest = None
for raw in sys.stdin:
    if "sync_progress_json=" not in raw:
        continue
    payload = raw.split("sync_progress_json=", 1)[1].strip()
    try:
        latest = json.loads(payload)
    except json.JSONDecodeError:
        continue
print(json.dumps(latest or {}))'
}

status_json() {
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    progress_json
  else
    status_command_json
  fi
}

field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null || echo "?"
}

benchmark_gate() {
  case "${BLOCKS_MAX:-0}" in
    5000) echo "baseline_5k" ;;
    10000) echo "diagnostic_10k" ;;
    50000) echo "shakedown_50k" ;;
    100000) echo "performance_100k" ;;
    *) echo "local_reference" ;;
  esac
}

emit_benchmark_tick() {
  local json="$1" last_height="$2" phase="$3" event="${4:-heartbeat}" process_running="${5:-1}"
  printf '%s\n' "$json" | \
    TARGET_BLOCK_HEIGHT="${BLOCKS_MAX:-0}" BENCHMARK_GATE="$(benchmark_gate)" \
    BENCHMARK_STARTED_MS="$started_ms" BENCHMARK_LAST_HEIGHT="$last_height" \
    BENCHMARK_PHASE="$phase" BENCHMARK_EVENT="$event" BENCHMARK_RUN_ID="$run_id" \
    BENCHMARK_PROCESS_RUNNING="$process_running" POLL_SEC="$POLL_SEC" \
    python3 scripts/emit_benchmark_telemetry_tick.py
}

pass_through_product_progress() {
  docker logs "$CONTAINER_NAME" 2>/dev/null | python3 - "$PROGRESS_STATE_FILE" <<'PY'
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
try:
    previous = int(state_path.read_text(encoding="utf-8").strip())
except Exception:
    previous = 0
lines = sys.stdin.read().splitlines()
for line in lines[previous:]:
    if "rb.port_progress " in line or "rb.port_progress=" in line:
        print(line)
state_path.write_text(str(len(lines)), encoding="utf-8")
PY
}

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_ms="$(now_ms)"
run_id="csharp-$(benchmark_gate)-$started_ms"
log_line "$(emit_benchmark_tick '{}' 0 startup run_started 0)"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
rm -f "$STATUS_FILE" "$EXIT_FILE" "$RUN_FILE" "$PROGRESS_STATE_FILE"
DOCKER_PROOF_VOLUME="${DOCKER_PROOF_VOLUME:-csbitnode_proof_data}" \
  SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
  HEADERS_MAX="${HEADERS_MAX:-200}" HEADER_BATCHES_MAX="${HEADER_BATCHES_MAX:-1}" BLOCKS_MAX="${BLOCKS_MAX:-2}" \
  TARGET_BLOCK_HEIGHT="${TARGET_BLOCK_HEIGHT:-${BLOCKS_MAX:-2}}" \
  BLOCK_PREFETCH_DEPTH="${BLOCK_PREFETCH_DEPTH:-1}" CSBITNODE_SYNC_TIMING="${CSBITNODE_SYNC_TIMING:-0}" \
  CSBITNODE_PROGRESS_JSON=1 PROGRESS_INTERVAL="$PROGRESS_INTERVAL" \
  "${DOCKER_COMPOSE[@]}" run -d --name "$CONTAINER_NAME" csbitnode-sync-proof >/dev/null
log_line "$(emit_benchmark_tick '{}' 0 startup container_started 1)"
log_line "$(emit_benchmark_tick '{}' 0 startup node_started 1)"

last_height=0
first_peer_byte=0
first_block_connected=0
while docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; do
  sleep "$POLL_SEC"
  json="$(status_json)"
  h="$(echo "$json" | field "print(d.get('validated_height','?'))")"
  header="$(echo "$json" | field "print(d.get('header_height','?'))")"
  stored="$(echo "$json" | field "print(d.get('stored_block_height','?'))")"
  status="$(echo "$json" | field "print(d.get('sync_status','?'))")"
  previous_height="$last_height"
  delta=0
  if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$last_height" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_height))
    last_height="$h"
  fi
  log_line "AGENT_LOOP_TICK_chatreport {\"validated_height\":$h,\"header_height\":$header,\"stored_block_height\":$stored,\"sync_status\":\"$status\",\"delta_since_last\":$delta,\"process_running\":1}"
  while IFS= read -r progress_line; do
    [[ -z "$progress_line" ]] && continue
    log_line "$progress_line"
  done < <(pass_through_product_progress || true)
  if [[ "$first_peer_byte" == "0" ]] && [[ "$header" =~ ^[0-9]+$ ]] && (( header > 0 )); then
    log_line "$(emit_benchmark_tick "$json" "$previous_height" peer_connect first_peer_byte 1)"
    first_peer_byte=1
  fi
  if [[ "$first_block_connected" == "0" ]] && [[ "$h" =~ ^[0-9]+$ ]] && (( h > 0 )); then
    log_line "$(emit_benchmark_tick "$json" "$previous_height" block_connect first_block_connected 1)"
    first_block_connected=1
  fi
  log_line "$(emit_benchmark_tick "$json" "$previous_height" heartbeat heartbeat 1)"
done

while IFS= read -r progress_line; do
  [[ -z "$progress_line" ]] && continue
  log_line "$progress_line"
done < <(pass_through_product_progress || true)

exit_code="$(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo 125)"
echo "$exit_code" > "$EXIT_FILE"
status_command_json > "$STATUS_FILE"
final_json="$(cat "$STATUS_FILE")"
final_height="$(echo "$final_json" | field "print(d.get('validated_height','?'))")"
if [[ "$final_height" =~ ^[0-9]+$ ]] && [[ "${BLOCKS_MAX:-0}" =~ ^[0-9]+$ ]] && (( final_height >= BLOCKS_MAX )); then
  log_line "$(emit_benchmark_tick "$final_json" "$last_height" complete target_reached 0)"
fi
log_line "$(emit_benchmark_tick "$final_json" "$last_height" complete run_finished 0)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_ms="$(now_ms)"
python3 - "$RUN_FILE" "$started_at" "$finished_at" "$started_ms" "$finished_ms" <<'PY'
import json
import pathlib
import sys

path, started_at, finished_at, started_ms, finished_ms = sys.argv[1:]
started = int(started_ms)
finished = int(finished_ms)
pathlib.Path(path).write_text(json.dumps({
    "started_at": started_at,
    "finished_at": finished_at,
    "elapsed_ms": max(0, finished - started),
}, indent=2) + "\n")
PY
docker logs "$CONTAINER_NAME" || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
exit "$exit_code"
