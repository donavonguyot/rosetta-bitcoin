#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REFERENCE_TOPOLOGY_ENV="${REFERENCE_TOPOLOGY_ENV:-../Shared/docker/reference_topology.env}"
DOCKER_COMPOSE=(docker compose --env-file "$REFERENCE_TOPOLOGY_ENV" -f docker/docker-compose.yml)

VOLUME="${DOCKER_PROOF_VOLUME:-jbitnode_100k_proof_data}"
PEERS="${PUBLIC_PEERS:?PUBLIC_PEERS=<peer1:48333,peer2:48333,...> is required for peer-rotation probe}"
BACKEND="${SECP256K1_BACKEND:-native}"
HEADERS_MAX="${HEADERS_MAX:-2000}"
HEADER_BATCHES_MAX="${HEADER_BATCHES_MAX:-50}"
BLOCKS_MAX="${BLOCKS_MAX:-64}"
RESULT_PATH="${PUBLIC_ROTATION_CAPABILITY_RESULT:-../Shared/testing/results/java_full_node_peer_rotation_reconnect_$(date +%F).json}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "peer_rotation_probe_start volume=$VOLUME peers=$PEERS"

if [ "${DOCKER_REBUILD:-0}" = "1" ]; then
  "${DOCKER_COMPOSE[@]}" build jbitnode-sync-proof
else
  echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"
fi

DOCKER_PROOF_VOLUME="$VOLUME" \
PUBLIC_PEERS="$PEERS" \
SECP256K1_BACKEND="$BACKEND" \
HEADERS_MAX="$HEADERS_MAX" \
HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" \
BLOCKS_MAX="$BLOCKS_MAX" \
"${DOCKER_COMPOSE[@]}" run --rm --no-deps \
  -e PAR_SCRIPT_VERIFY=1 \
  -e SECP256K1_BACKEND="$BACKEND" \
  -e PUBLIC_PEERS="$PEERS" \
  -e HEADERS_MAX="$HEADERS_MAX" \
  -e HEADER_BATCHES_MAX="$HEADER_BATCHES_MAX" \
  -e BLOCKS_MAX="$BLOCKS_MAX" \
  -e PUBLIC_ROTATION_RESULT_PATH=/probe-out/java_public_peer_rotation_probe.json \
  -v "$TMPDIR:/probe-out" \
  jbitnode-sync-proof com.jbitnode.cli.PublicPeerRotationProbe

python3 scripts/emit_peer_rotation_capability.py \
  --probe-result "$TMPDIR/java_public_peer_rotation_probe.json" \
  --result-path "$RESULT_PATH"

echo "peer_rotation_probe_capability_result=$RESULT_PATH"
