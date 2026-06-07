SWIFT ?= swift
DATA_DIR ?= ./data-swift
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/swift_script_corpus_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /results/swift_script_corpus_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /results/swift_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_PROOF_RESULT ?= /results/swift_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= /results/swift_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_100K_PROOF_RESULT ?= /results/swift_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
LOCAL_P2P_PEER ?= 127.0.0.1:48333
DOCKER_PROOF_VOLUME ?= swiftbitnode_proof_data
DOCKER_SYNC_TARGET ?= 5000
BENCHMARK_GATE ?= baseline_5k
DOCKER_SUPERVISOR_TARGET ?= 10000
DOCKER_SUPERVISOR_CHUNK ?= 5000
DOCKER_SUPERVISOR_RESULT ?= /results/swift_supervisor_status_$(RESULT_DATE).json

.PHONY: build test swift-node-status swift-node-native-crypto-vectors swift-node-script-corpus swift-node-proof-local swift-node-sync-supervisor docker-config docker-build docker-warm docker-status docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-supervisor docker-supervisor-status docker-supervisor-stop docker-supervisor-resume docker-smoke-once clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

swift-node-status:
	$(SWIFT) run swiftbitnode status --datadir $(DATA_DIR)

swift-node-native-crypto-vectors:
	$(SWIFT) run swiftbitnode native-crypto-vectors

swift-node-script-corpus:
	$(SWIFT) run swiftbitnode script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(SCRIPT_RESULT)

swift-node-proof-local:
	$(SWIFT) run swiftbitnode proof-local \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(LOCAL_P2P_PEER) \
	  --output ../Shared/conformance/results/swift_docker_baseline_5k_benchmark_$(RESULT_DATE).json

swift-node-sync-supervisor:
	$(SWIFT) run swiftbitnode sync-supervisor \
	  --target $(DOCKER_SUPERVISOR_TARGET) \
	  --chunk-size $(DOCKER_SUPERVISOR_CHUNK) \
	  --peer $(LOCAL_P2P_PEER) \
	  --datadir $(DATA_DIR)

docker-config:
	$(DOCKER_COMPOSE) config >/dev/null

docker-build:
	$(DOCKER_COMPOSE) build

docker-warm: docker-build

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode swiftbitnode status --datadir /data

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode-script-corpus \
	  swiftbitnode script-corpus \
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
	  -e SWIFTBITNODE_LEGACY_UTXO_FALLBACK=false \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  swiftbitnode-local-reference-proof \
	  swiftbitnode proof-local \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --output $(DOCKER_LOCAL_PROOF_RESULT)
	@if [ "$(BENCHMARK_GATE)" != "diagnostic_10k" ]; then \
	  $(VALIDATE_BENCHMARK_ARTIFACT) --gate $(BENCHMARK_GATE) --artifact $(patsubst /results/%,../Shared/conformance/results/%,$(DOCKER_LOCAL_PROOF_RESULT)) --port swift --strict-current; \
	fi

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=swiftbitnode_10k_proof_data \
	  DOCKER_SYNC_TARGET=10000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_10K_PROOF_RESULT) \
	  BENCHMARK_GATE=diagnostic_10k

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=swiftbitnode_50k_proof_data \
	  DOCKER_SYNC_TARGET=50000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT) \
	  BENCHMARK_GATE=shakedown_50k

docker-proof-100k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=swiftbitnode_100k_proof_data \
	  DOCKER_SYNC_TARGET=100000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_100K_PROOF_RESULT) \
	  BENCHMARK_GATE=performance_100k

docker-supervisor:
	$(REFERENCE_P2P_CHECK)
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e TARGET_HEIGHT=$(DOCKER_SUPERVISOR_TARGET) \
	  -e CHUNK_SIZE=$(DOCKER_SUPERVISOR_CHUNK) \
	  -e PREFETCH_DEPTH=4 \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  swiftbitnode \
	  swiftbitnode sync-supervisor \
	  --target $(DOCKER_SUPERVISOR_TARGET) \
	  --chunk-size $(DOCKER_SUPERVISOR_CHUNK) \
	  --peer $(DOCKER_P2P_PEER) \
	  --datadir /data \
	  --output $(DOCKER_SUPERVISOR_RESULT)

docker-supervisor-status:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode swiftbitnode status --datadir /data

docker-supervisor-stop:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode /bin/sh -lc 'touch /data/.swiftbitnode_supervisor_stop'

docker-supervisor-resume:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode /bin/sh -lc 'rm -f /data/.swiftbitnode_supervisor_stop'

docker-smoke-once:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  -e PEER_MODE=local_reference \
	  swiftbitnode swiftbitnode supervisor-smoke-once --datadir /data

clean:
	rm -rf .build data-swift
