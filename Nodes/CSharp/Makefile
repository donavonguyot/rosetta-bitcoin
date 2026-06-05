DOTNET_ROOT ?= /opt/homebrew/opt/dotnet@8/libexec
DOTNET = $(DOTNET_ROOT)/dotnet
PROJECT = src/CsBitNode/CsBitNode.csproj
TEST_PROJECT = tests/CsBitNode.Tests/CsBitNode.Tests.csproj
DATA_DIR ?= ./data-csharp
PEERS ?= 127.0.0.1:48333

DOCKER_PROOF_VOLUME ?= csbitnode_proof_data
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/csharp_native_crypto_docker_smoke_2026-06-01.json
RESULT_DATE ?= $(shell date +%F)
SUPPORTING_5K_RESULT ?= ../Shared/conformance/results/csharp_docker_supporting_5k_benchmark_$(RESULT_DATE).json
SUPPORTING_10K_RESULT ?= ../Shared/conformance/results/csharp_docker_supporting_10k_benchmark_$(RESULT_DATE).json
SCRIPT_RESULT ?= ../Shared/conformance/results/csharp_script_corpus_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/csharp_script_corpus_docker_$(RESULT_DATE).json
DOCKER_HEADERS_MAX ?= 200
DOCKER_HEADER_BATCHES_MAX ?= 1
DOCKER_BLOCKS_MAX ?= 2
DOCKER_PREFETCH_DEPTH ?= 4
DOCKER_SCRIPT_RUNNER_MODE ?= parallel
DOCKER_P2P_PEER ?= host.docker.internal:48333
DOCKER_SYNC_VOLUME ?= csbitnode_sync_data
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_REBUILD ?= 0

.PHONY: build test docker-config docker-build docker-warm node-status sync-local csharp-node-native-sync csharp-node-native-status csharp-node-storage-proof csharp-node-script-corpus csharp-node-rocksdb-replay-proof csharp-node-native-crypto-test docker-script-corpus docker-proof-local docker-proof-10k docker-csharp-native-crypto-proof docker-csharp-native-crypto-bounded-sync-proof docker-csharp-sync-supervisor docker-csharp-sync-status docker-csharp-sync-stop docker-csharp-sync-resume export-snapshots clean

build:
	$(DOTNET) build $(PROJECT) -c Release

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build csbitnode-sync-proof

docker-warm: docker-build

test:
	$(DOTNET) test $(TEST_PROJECT) -c Release

csharp-node-native-crypto-test:
	SECP256K1_BACKEND=native $(DOTNET) test $(TEST_PROJECT) -c Release

csharp-node-script-corpus:
	SECP256K1_BACKEND=native $(DOTNET) run --project $(PROJECT) -c Release -- script-corpus --result-path $(SCRIPT_RESULT)

node-status:
	DATA_DIR=$(DATA_DIR) $(DOTNET) run --project $(PROJECT) -c Release --no-build 2>/dev/null || \
	DATA_DIR=$(DATA_DIR) $(DOTNET) run --project $(PROJECT) -c Release

sync-local:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) FIXTURE_BLOCKS_DIR=$(FIXTURE_BLOCKS_DIR) HEADERS_MAX=$(or $(HEADERS_MAX),2000) \
	HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) BLOCKS_MAX=$(or $(BLOCKS_MAX),128) \
	CSBITNODE_TOOL=sync $(DOTNET) run --project $(PROJECT) -c Release -- sync

csharp-node-native-sync:
	$(MAKE) sync-local DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) FIXTURE_BLOCKS_DIR=$(FIXTURE_BLOCKS_DIR) HEADERS_MAX=$(HEADERS_MAX) HEADER_BATCHES_MAX=$(HEADER_BATCHES_MAX) BLOCKS_MAX=$(BLOCKS_MAX)

csharp-node-native-status:
	DATA_DIR=$(DATA_DIR) $(DOTNET) run --project $(PROJECT) -c Release --no-build 2>/dev/null || \
	DATA_DIR=$(DATA_DIR) $(DOTNET) run --project $(PROJECT) -c Release

csharp-node-storage-proof:
	DATA_DIR=$(DATA_DIR) NODE_ID=$(or $(NODE_ID),csharpnode-native) SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) \
	$(DOTNET) run --project $(PROJECT) -c Release --no-build -- --storage-proof 2>/dev/null || \
	DATA_DIR=$(DATA_DIR) NODE_ID=$(or $(NODE_ID),csharpnode-native) SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) \
	$(DOTNET) run --project $(PROJECT) -c Release -- --storage-proof

csharp-node-rocksdb-replay-proof:
	DATA_DIR=$(DATA_DIR) FIXTURE_BLOCKS_DIR=$(or $(FIXTURE_BLOCKS_DIR),tests/CsBitNode.Tests/Fixtures) \
	REPLAY_CORPUS_DIR=$(REPLAY_CORPUS_DIR) SOURCE_DATA_DIR=$(SOURCE_DATA_DIR) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),2) \
	CSBITNODE_TOOL=storage-proof-seed $(DOTNET) run --project $(PROJECT) -c Release -- --storage-proof-seed
	$(MAKE) csharp-node-storage-proof DATA_DIR=$(DATA_DIR) NODE_ID=$(or $(NODE_ID),csharpnode-rocksdb-codec-v2)

docker-csharp-native-crypto-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build csbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) SECP256K1_BACKEND=native \
	  HEADERS_MAX=$(DOCKER_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_HEADER_BATCHES_MAX) BLOCKS_MAX=$(DOCKER_BLOCKS_MAX) \
	  PEERS=$(DOCKER_P2P_PEER) \
	  BLOCK_PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) SCRIPT_RUNNER_MODE=$(DOCKER_SCRIPT_RUNNER_MODE) \
	  CSBITNODE_SYNC_TIMING=$(or $(CSBITNODE_SYNC_TIMING),0) POLL_SEC=$(or $(POLL_SEC),120) \
	  scripts/docker_sync_proof.sh || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) PROOF_PATH=$(DOCKER_PROOF_PATH) \
	  TARGET_HEADER_HEIGHT=$(DOCKER_HEADERS_MAX) TARGET_BLOCK_HEIGHT=$(DOCKER_BLOCKS_MAX) \
	  BLOCK_PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) SCRIPT_RUNNER_MODE=$(DOCKER_SCRIPT_RUNNER_MODE) \
	  STANDARD_BENCHMARK_ARTIFACT=$(or $(STANDARD_BENCHMARK_ARTIFACT),0) \
	  CSBITNODE_ROCKSDB_DISABLE_WAL=$(or $(CSBITNODE_ROCKSDB_DISABLE_WAL),0) \
	  PEERS=$(DOCKER_P2P_PEER) \
	  PROOF_COMMAND="$(or $(PROOF_COMMAND),make docker-csharp-native-crypto-proof)" \
	  POLL_SEC=$(or $(POLL_SEC),120) \
	  python3 scripts/capture_docker_sync_proof.py .docker-csharp-proof-status.json .docker-csharp-proof-exit
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/csbitnode.db

docker-script-corpus:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build csbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	SECP256K1_BACKEND=native $(DOCKER_COMPOSE) run --rm --no-deps \
	  -v $(abspath ../Shared/conformance):/shared/conformance \
	  csbitnode-sync-proof script-corpus \
	  --manifest /shared/conformance/fixtures/scripts/manifest.json \
	  --result-path $(DOCKER_SCRIPT_RESULT) \
	  --runtime-surface docker

docker-proof-local:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	$(MAKE) docker-csharp-native-crypto-proof \
	  DOCKER_PROOF_VOLUME=csbitnode_proof_data \
	  DOCKER_PROOF_PATH=$(SUPPORTING_5K_RESULT) \
	  DOCKER_HEADERS_MAX=5000 \
	  DOCKER_HEADER_BATCHES_MAX=50 \
	  DOCKER_BLOCKS_MAX=5000 \
	  DOCKER_PREFETCH_DEPTH=4 \
	  DOCKER_SCRIPT_RUNNER_MODE=parallel \
	  CSBITNODE_SYNC_TIMING=1 \
	  STANDARD_BENCHMARK_ARTIFACT=1 \
	  PROOF_COMMAND="make docker-proof-local" \
	  POLL_SEC=15

docker-proof-10k:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	$(MAKE) docker-csharp-native-crypto-proof \
	  DOCKER_PROOF_VOLUME=csbitnode_10k_proof_data \
	  DOCKER_PROOF_PATH=$(SUPPORTING_10K_RESULT) \
	  DOCKER_HEADERS_MAX=10000 \
	  DOCKER_HEADER_BATCHES_MAX=50 \
	  DOCKER_BLOCKS_MAX=10000 \
	  DOCKER_PREFETCH_DEPTH=4 \
	  DOCKER_SCRIPT_RUNNER_MODE=parallel \
	  CSBITNODE_SYNC_TIMING=1 \
	  STANDARD_BENCHMARK_ARTIFACT=1 \
	  PROOF_COMMAND="make docker-proof-10k" \
	  POLL_SEC=15

docker-csharp-native-crypto-bounded-sync-proof:
	$(MAKE) docker-csharp-native-crypto-proof \
	  DOCKER_PROOF_VOLUME=csbitnode_native_bounded_sync_data \
	  DOCKER_PROOF_PATH=../Shared/conformance/results/csharp_native_crypto_docker_bounded_sync_2026-06-01.json \
	  DOCKER_HEADERS_MAX=$(or $(DOCKER_HEADERS_MAX),10000) \
	  DOCKER_HEADER_BATCHES_MAX=$(or $(DOCKER_HEADER_BATCHES_MAX),50) \
	  DOCKER_BLOCKS_MAX=$(or $(DOCKER_BLOCKS_MAX),10000)

docker-csharp-sync-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  DOCKER_REBUILD=$(DOCKER_REBUILD) \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-csharp-sync-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  $(DOCKER_COMPOSE) run --rm --no-deps csbitnode-sync-proof status

docker-csharp-sync-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.csbitnode_supervisor_stop'

docker-csharp-sync-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.csbitnode_supervisor_resume'

export-snapshots:
	@echo "export-snapshots not implemented yet; use node-status for live DB fields"

clean:
	$(DOTNET) clean
	rm -rf data-csharp-smoke data-csharp-native-proof data-csharp-live-smoke
