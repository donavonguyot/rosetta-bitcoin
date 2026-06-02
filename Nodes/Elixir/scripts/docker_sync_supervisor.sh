#!/usr/bin/env bash
set -euo pipefail

DOCKER_COMPOSE=${DOCKER_COMPOSE:-"docker compose -f docker/docker-compose.yml"}
DOCKER_PROOF_VOLUME=${DOCKER_PROOF_VOLUME:-exbitnode_sync_data}
POLL_SEC=${POLL_SEC:-120}
CHECK_SEC=${CHECK_SEC:-5}
SUPERVISOR_ONCE=${SUPERVISOR_ONCE:-0}

tick() {
  local phase="$1"
  DOCKER_PROOF_VOLUME="$DOCKER_PROOF_VOLUME" RUNTIME_SURFACE=supervisor \
    $DOCKER_COMPOSE run --rm --no-deps exbitnode-sync-proof mix node.status \
    | python3 -c 'import json,sys; s=sys.stdin.read(); start=s.find("{"); end=s.rfind("}"); d=json.loads(s[start:end+1]); d["phase"]=sys.argv[1]; d["peer_mode"]="local_reference"; d["peer"]=d.get("peer_source",""); d["process_running"]=False; d["delta_since_last"]=0; print("AGENT_LOOP_TICK_chatreport " + json.dumps(d, sort_keys=True))' "$phase"
}

while true; do
  if docker run --rm -v "$DOCKER_PROOF_VOLUME":/data alpine:3.20 test -f /data/.exbitnode_supervisor_stop; then
    tick "stopped"
    exit 0
  fi

  tick "before_sync"

  if [ "${BLOCKS_MAX:-0}" != "0" ]; then
    DOCKER_PROOF_VOLUME="$DOCKER_PROOF_VOLUME" RUNTIME_SURFACE=supervisor \
      $DOCKER_COMPOSE run --rm --no-deps exbitnode-sync-proof mix sync.local || true
  fi

  tick "after_sync"

  if [ "$SUPERVISOR_ONCE" = "1" ]; then
    exit 0
  fi

  sleep "$POLL_SEC"
  sleep "$CHECK_SEC"
done
