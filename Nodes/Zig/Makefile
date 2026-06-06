ZIG ?= zig
DATA_DIR ?= ./data-zig
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/zig_script_corpus_$(RESULT_DATE).json
STORAGE_RESULT ?= ../Shared/conformance/results/zig_storage_gate_docker_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /results/zig_script_corpus_$(RESULT_DATE).json
DOCKER_STORAGE_RESULT ?= /results/zig_storage_gate_docker_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /results/zig_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_PROOF_RESULT ?= /results/zig_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= /results/zig_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_100K_PROOF_RESULT ?= /results/zig_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
DOCKER_PROOF_VOLUME ?= zigbitnode_proof_data
DOCKER_SYNC_TARGET ?= 5000
BENCHMARK_GATE ?= baseline_5k

.PHONY: build test zig-node-status zig-node-storage-proof zig-node-codec-vectors zig-node-native-crypto-vectors zig-node-script-corpus docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-smoke-once clean

build:
	$(ZIG) build

test:
	$(ZIG) build test

zig-node-status:
	$(ZIG) build run -- status --datadir $(DATA_DIR)

zig-node-storage-proof:
	$(ZIG) build run -- storage-proof --datadir $(DATA_DIR) --output $(STORAGE_RESULT)

zig-node-codec-vectors:
	$(ZIG) build run -- codec-vectors

zig-node-native-crypto-vectors:
	$(ZIG) build run -- native-crypto-vectors

zig-node-script-corpus:
	$(ZIG) build run -- script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(SCRIPT_RESULT)

docker-config:
	$(DOCKER_COMPOSE) config >/dev/null

docker-build:
	$(DOCKER_COMPOSE) build

docker-warm: docker-build

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps zigbitnode zigbitnode status --datadir /data

docker-storage-proof:
	$(DOCKER_COMPOSE) run --rm --no-deps zigbitnode \
	  zigbitnode storage-proof --datadir /data --output $(DOCKER_STORAGE_RESULT)

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm --no-deps zigbitnode-script-corpus \
	  zigbitnode script-corpus \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(DOCKER_SCRIPT_RESULT)

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e HEADER_TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e PREFETCH_DEPTH=4 \
	  -e SCRIPT_RUNNER_MODE=parallel \
	  -e ROCKSDB_WAL_DISABLED=false \
	  -e FRESH_STATE=true \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  zigbitnode-local-reference-proof \
	  zigbitnode local-reference-proof \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --output $(DOCKER_LOCAL_PROOF_RESULT)
	@if [ "$(BENCHMARK_GATE)" != "diagnostic_10k" ]; then \
	  $(VALIDATE_BENCHMARK_ARTIFACT) --gate $(BENCHMARK_GATE) --artifact $(patsubst /results/%,../Shared/conformance/results/%,$(DOCKER_LOCAL_PROOF_RESULT)) --port zig --strict-current; \
	fi

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=zigbitnode_10k_proof_data \
	  DOCKER_SYNC_TARGET=10000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_10K_PROOF_RESULT) \
	  BENCHMARK_GATE=diagnostic_10k

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=zigbitnode_50k_proof_data \
	  DOCKER_SYNC_TARGET=50000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT) \
	  BENCHMARK_GATE=shakedown_50k

docker-proof-100k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=zigbitnode_100k_proof_data \
	  DOCKER_SYNC_TARGET=100000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_100K_PROOF_RESULT) \
	  BENCHMARK_GATE=performance_100k

docker-smoke-once: docker-status docker-storage-proof docker-script-corpus

clean:
	rm -rf .zig-cache zig-cache zig-out data-zig data-zig-*
