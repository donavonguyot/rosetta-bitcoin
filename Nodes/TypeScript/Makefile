DATA_DIR ?= ./data-ts-native
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_PROOF_VOLUME ?= tsbitnode_proof_data
DOCKER_SYNC_VOLUME ?= tsbitnode_sync_data
DOCKER_REBUILD ?= 0
DOCKER_SYNC_TARGET ?= 5000
DOCKER_SYNC_BLOCKS_MAX ?= 5000
DOCKER_BENCHMARK_PREFETCH_DEPTH ?= 4
DOCKER_BENCHMARK_RESULT ?= ../Shared/conformance/results/typescript_docker_supporting_5k_benchmark_$(shell date +%F).json
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5

.PHONY: build test native-status storage-proof docker-config docker-build docker-warm docker-typescript-native-proof docker-typescript-sync-status docker-typescript-sync-supervisor docker-typescript-sync-stop docker-typescript-sync-resume docker-smoke-once

build:
	npm run build

test:
	npm test

native-status:
	DATA_DIR=$(DATA_DIR) node dist/cli/nativeStatus.js --datadir $(DATA_DIR)

storage-proof:
	DATA_DIR=$(DATA_DIR) node dist/cli/storageProof.js --datadir $(DATA_DIR)

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build tsbitnode-sync-proof tsbitnode-sync-status

docker-warm: docker-build

docker-typescript-native-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build tsbitnode-sync-proof tsbitnode-sync-status; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) SECP256K1_BACKEND=native \
	  DOCKER_SYNC_TARGET=$(DOCKER_SYNC_TARGET) DOCKER_SYNC_BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) \
	  DOCKER_BENCHMARK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) \
	  DOCKER_BENCHMARK_RESULT=$(DOCKER_BENCHMARK_RESULT) \
	  scripts/docker_5k_benchmark.sh
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/tsbitnode.db

docker-typescript-sync-status:
	DOCKER_SYNC_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  $(DOCKER_COMPOSE) run --rm --no-deps tsbitnode-sync-status

docker-typescript-sync-supervisor:
	DOCKER_SYNC_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  DOCKER_REBUILD=$(DOCKER_REBUILD) \
	  POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-typescript-sync-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.tsbitnode_supervisor_stop'

docker-typescript-sync-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.tsbitnode_supervisor_resume'

docker-smoke-once:
	SUPERVISOR_ONCE=1 POLL_SEC=1 CHECK_SEC=1 DOCKER_SYNC_VOLUME=$(DOCKER_SYNC_VOLUME) scripts/docker_sync_supervisor.sh
