MIX ?= mix
DATA_DIR ?= ./data-elixir
PEERS ?= 127.0.0.1:48333
DOCKER_COMPOSE ?= docker compose -f docker/docker-compose.yml
DOCKER_PEERS ?= host.docker.internal:48333
DOCKER_REBUILD ?= 0
DOCKER_PROOF_VOLUME ?= exbitnode_proof_data
DOCKER_SYNC_VOLUME ?= exbitnode_sync_data
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/elixir_rocksdb_codec_v2_storage.json
DOCKER_LONG_PROOF_VOLUME ?= exbitnode_native_10k_sync_data
DOCKER_LONG_PROOF_PATH ?= ../Shared/conformance/results/elixir_native_docker_10k_sync_20260603.json
DOCKER_LONG_HEADERS_MAX ?= 10000
DOCKER_LONG_HEADER_BATCHES_MAX ?= 50
DOCKER_LONG_BLOCKS_MAX ?= 10000
DOCKER_LONG_TARGET_HEADER_HEIGHT ?= $(DOCKER_LONG_HEADERS_MAX)
DOCKER_LONG_TARGET_BLOCK_HEIGHT ?= $(DOCKER_LONG_BLOCKS_MAX)
DOCKER_HEADERS_MAX ?= 200
DOCKER_HEADER_BATCHES_MAX ?= 1
DOCKER_BLOCKS_MAX ?= 2
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5

.PHONY: test status node-status sync-local storage-proof script-corpus docker-config docker-build docker-warm docker-status docker-proof-local docker-long-sync-proof docker-10k-sync-proof docker-supervisor docker-supervisor-status docker-supervisor-stop docker-supervisor-resume docker-smoke-once clean

test:
	$(MIX) test

status:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) $(MIX) status

node-status: status

sync-local:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) HEADERS_MAX=$(or $(HEADERS_MAX),2000) \
	HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),128) SKIP_BLOCKS=$(SKIP_BLOCKS) \
	$(MIX) sync.local

storage-proof:
	DATA_DIR=$(DATA_DIR) PROOF_PATH=$(or $(PROOF_PATH),../Shared/conformance/results/elixir_rocksdb_codec_v2_storage.json) $(MIX) storage.proof

script-corpus:
	$(MIX) script.corpus -- --manifest $(or $(MANIFEST),../Shared/conformance/fixtures/scripts/manifest.json) --result-path $(or $(RESULT_PATH),../Shared/conformance/results/elixir_script_corpus.json)

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build exbitnode-sync-proof

docker-warm: docker-build

docker-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status

docker-proof-local:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build exbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) RUNTIME_SURFACE=docker PROOF_PATH=/tmp/elixir_storage_proof.json \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix storage.proof
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 sh -c '! find /data -maxdepth 1 \( -name "*.db" -o -name "*.db-wal" -o -name "*.db-shm" -o -name "*.sqlite" -o -name "*.sqlite3" \) | grep -q .'

docker-long-sync-proof:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f $(DOCKER_LONG_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) RUNTIME_SURFACE=docker_supervisor \
	  PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=$(DOCKER_LONG_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_LONG_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_LONG_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  SUPERVISOR_ONCE=1 scripts/docker_sync_supervisor.sh || true
	@docker run --rm -v $(DOCKER_LONG_PROOF_VOLUME):/data alpine:3.20 sh -c 'cat /data/.exbitnode_last_sync_exit 2>/dev/null || echo 0' > .docker-elixir-long-sync-exit
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) RUNTIME_SURFACE=docker \
	  PEERS=$(DOCKER_PEERS) \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status > .docker-elixir-long-status.json || true
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) \
	  TARGET_HEADER_HEIGHT=$(DOCKER_LONG_TARGET_HEADER_HEIGHT) TARGET_BLOCK_HEIGHT=$(DOCKER_LONG_TARGET_BLOCK_HEIGHT) \
	  PROOF_PATH=$(DOCKER_LONG_PROOF_PATH) PROOF_COMMAND="$(or $(PROOF_COMMAND),$(MAKE) docker-long-sync-proof)" \
	  python3 ../Shared/conformance/tools/proofs/capture_elixir_docker_long_sync_proof.py .docker-elixir-long-status.json .docker-elixir-long-sync-exit
	@rm -f .docker-elixir-long-status.json .docker-elixir-long-sync-exit
	@docker run --rm -v $(DOCKER_LONG_PROOF_VOLUME):/data alpine:3.20 sh -c '! find /data -maxdepth 1 \( -name "*.db" -o -name "*.db-wal" -o -name "*.db-shm" -o -name "*.sqlite" -o -name "*.sqlite3" \) | grep -q .'

docker-10k-sync-proof:
	$(MAKE) docker-long-sync-proof \
	  DOCKER_LONG_HEADERS_MAX=10000 \
	  DOCKER_LONG_HEADER_BATCHES_MAX=50 \
	  DOCKER_LONG_BLOCKS_MAX=10001 \
	  DOCKER_LONG_TARGET_HEADER_HEIGHT=10000 \
	  DOCKER_LONG_TARGET_BLOCK_HEIGHT=10000 \
	  DOCKER_LONG_PROOF_VOLUME=exbitnode_native_10k_sync_data \
	  DOCKER_LONG_PROOF_PATH=../Shared/conformance/results/elixir_native_docker_10k_sync_20260603.json \
	  PROOF_COMMAND="$(MAKE) docker-10k-sync-proof"

docker-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-supervisor-status:
	@$(MAKE) docker-status || true

docker-supervisor-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_stop'

docker-supervisor-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_resume'

docker-smoke-once:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=0 HEADER_BATCHES_MAX=0 BLOCKS_MAX=0 POLL_SEC=1 CHECK_SEC=1 SUPERVISOR_ONCE=1 \
	  scripts/docker_sync_supervisor.sh

clean:
	$(MIX) clean
	rm -rf _build deps data-elixir-smoke
