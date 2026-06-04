#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKER_COMPOSE=(docker compose -f docker/docker-compose.yml)
POLL_SEC="${POLL_SEC:-120}"
CONTAINER_NAME="${CONTAINER_NAME:-csbitnode-sync-proof-run}"
STATUS_FILE="${STATUS_FILE:-.docker-csharp-proof-status.json}"
EXIT_FILE="${EXIT_FILE:-.docker-csharp-proof-exit}"
RUN_FILE="${RUN_FILE:-.docker-csharp-proof-run.json}"

log_line() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

status_json() {
  DOCKER_PROOF_VOLUME="${DOCKER_PROOF_VOLUME:-csbitnode_proof_data}" \
  SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
  "${DOCKER_COMPOSE[@]}" run --rm --no-deps csbitnode-sync-proof status 2>/dev/null || echo '{}'
}

field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null || echo "?"
}

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_ms="$(now_ms)"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
DOCKER_PROOF_VOLUME="${DOCKER_PROOF_VOLUME:-csbitnode_proof_data}" \
  SECP256K1_BACKEND="${SECP256K1_BACKEND:-native}" \
  HEADERS_MAX="${HEADERS_MAX:-200}" HEADER_BATCHES_MAX="${HEADER_BATCHES_MAX:-1}" BLOCKS_MAX="${BLOCKS_MAX:-2}" \
  BLOCK_PREFETCH_DEPTH="${BLOCK_PREFETCH_DEPTH:-1}" CSBITNODE_SYNC_TIMING="${CSBITNODE_SYNC_TIMING:-0}" \
  "${DOCKER_COMPOSE[@]}" run -d --name "$CONTAINER_NAME" csbitnode-sync-proof >/dev/null

last_height=0
while docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; do
  sleep "$POLL_SEC"
  json="$(status_json)"
  h="$(echo "$json" | field "print(d.get('validated_height','?'))")"
  header="$(echo "$json" | field "print(d.get('header_height','?'))")"
  stored="$(echo "$json" | field "print(d.get('stored_block_height','?'))")"
  status="$(echo "$json" | field "print(d.get('sync_status','?'))")"
  delta=0
  if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$last_height" =~ ^[0-9]+$ ]]; then
    delta=$((h - last_height))
    last_height="$h"
  fi
  log_line "AGENT_LOOP_TICK_chatreport {\"validated_height\":$h,\"header_height\":$header,\"stored_block_height\":$stored,\"sync_status\":\"$status\",\"delta_since_last\":$delta,\"process_running\":1}"
done

exit_code="$(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo 125)"
echo "$exit_code" > "$EXIT_FILE"
status_json > "$STATUS_FILE"
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
