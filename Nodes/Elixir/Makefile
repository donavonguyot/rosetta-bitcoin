MIX ?= mix
DATA_DIR ?= ./data-elixir
PEERS ?= 127.0.0.1:48333
DOCKER_COMPOSE ?= docker compose -f docker/docker-compose.yml
DOCKER_PROOF_VOLUME ?= exbitnode_proof_data
DOCKER_SYNC_VOLUME ?= exbitnode_sync_data
DOCKER_PROOF_PATH ?= ../../NodeCore/conformance/results/elixir_rocksdb_codec_v2_storage.json
DOCKER_HEADERS_MAX ?= 200
DOCKER_HEADER_BATCHES_MAX ?= 1
DOCKER_BLOCKS_MAX ?= 2
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5

.PHONY: test status node-status sync-local storage-proof docker-config docker-build docker-status docker-proof-local docker-supervisor docker-supervisor-status docker-supervisor-stop docker-supervisor-resume docker-smoke-once clean

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
	DATA_DIR=$(DATA_DIR) PROOF_PATH=$(or $(PROOF_PATH),../../NodeCore/conformance/results/elixir_rocksdb_codec_v2_storage.json) $(MIX) storage.proof

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build exbitnode-sync-proof

docker-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status

docker-proof-local:
	$(DOCKER_COMPOSE) build exbitnode-sync-proof
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) RUNTIME_SURFACE=docker PROOF_PATH=/tmp/elixir_storage_proof.json \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix storage.proof
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 sh -c 'test ! -f /data/exbitnode.db'

docker-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(PEERS) \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-supervisor-status:
	$(MAKE) docker-status

docker-supervisor-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_stop'

docker-supervisor-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_resume'

docker-smoke-once:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(PEERS) \
	  HEADERS_MAX=0 HEADER_BATCHES_MAX=0 BLOCKS_MAX=0 POLL_SEC=1 CHECK_SEC=1 SUPERVISOR_ONCE=1 \
	  scripts/docker_sync_supervisor.sh

clean:
	$(MIX) clean
	rm -rf _build deps data-elixir-smoke
