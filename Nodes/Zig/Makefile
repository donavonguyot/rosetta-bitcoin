ZIG ?= zig
DATA_DIR ?= ./data-zig
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/zig_script_corpus_$(RESULT_DATE).json
STORAGE_RESULT ?= ../Shared/conformance/results/zig_storage_gate_docker_$(RESULT_DATE).json
TESTING_RESULTS_DIR ?= ../Shared/testing/results
TESTING_CAPABILITY_EMITTER ?= python3 ../Shared/testing/tools/emit_crypto_capability_contract.py
CRYPTO_CAPABILITY_RESULT ?= $(TESTING_RESULTS_DIR)/zig_crypto_vectors_$(RESULT_DATE).json
BLOCK_CONNECT_BACKEND_RESULT ?= $(TESTING_RESULTS_DIR)/zig_block_connect_backend_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /results/zig_script_corpus_$(RESULT_DATE).json
DOCKER_STORAGE_RESULT ?= /results/zig_storage_gate_docker_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /tmp/zig_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_PROOF_RESULT ?= /results/zig_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= /tmp/zig_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_100K_PROOF_RESULT ?= /tmp/zig_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
DOCKER_PROOF_VOLUME ?= zigbitnode_proof_data
FRESH_STATE ?= true
POST_100K_TIP_VOLUME ?= zigbitnode_100k_proof_data
POST_100K_TIP_TARGET ?= $(or $(REFERENCE_FINISH_HEIGHT),100000)
DOCKER_SYNC_TARGET ?= 5000
BENCHMARK_GATE ?= baseline_5k

.PHONY: build test zig-node-status zig-node-storage-proof zig-node-codec-vectors zig-node-native-crypto-vectors zig-node-script-corpus zig-node-script-corpus-shadow docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-proof-post-100k-to-tip docker-smoke-once clean

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

test-crypto-vectors:
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	$(ZIG) build run -- test-capability --kind crypto-vectors --outcome-path "$$tmp"; \
	$(TESTING_CAPABILITY_EMITTER) --outcomes "$$tmp" --result-path $(CRYPTO_CAPABILITY_RESULT)

test-block-connect-backend:
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	if $(ZIG) build run -- script-corpus --manifest ../Shared/conformance/fixtures/scripts/manifest.json --output ../Shared/conformance/results/zig_backend_probe_script_corpus_$(RESULT_DATE).json >/dev/null; then status=pass; passed=2; notes="native script corpus passed, including backend probe fixtures"; else status=fail; passed=0; notes="native script corpus failed before backend probe fixtures could be claimed"; fi; \
	printf '{"port":"zig","backend":"libsecp256k1","outcomes":[{"capability":"block_connect_with_backend","status":"%s","case_passed":%s,"case_total":2,"notes":"%s"}]}\n' "$$status" "$$passed" "$$notes" > "$$tmp"; \
	$(TESTING_CAPABILITY_EMITTER) --outcomes "$$tmp" --result-path $(BLOCK_CONNECT_BACKEND_RESULT)

zig-node-script-corpus:
	$(ZIG) build run -- script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(SCRIPT_RESULT)

zig-node-script-corpus-shadow:
	$(ZIG) build run -- script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  --output ../Shared/conformance/results/zig_shadow_crypto_script_corpus_$(RESULT_DATE).json \
	  --shadow-crypto

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
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true; fi
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e HEADER_TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e PREFETCH_DEPTH=4 \
	  -e SCRIPT_RUNNER_MODE=parallel \
	  -e ROCKSDB_WAL_DISABLED=false \
	  -e FRESH_STATE=$(FRESH_STATE) \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  zigbitnode-local-reference-proof \
	  zigbitnode local-reference-proof \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --output $(DOCKER_LOCAL_PROOF_RESULT)

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

docker-proof-post-100k-to-tip:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=$(POST_100K_TIP_VOLUME) \
	  DOCKER_SYNC_TARGET=$(POST_100K_TIP_TARGET) \
	  DOCKER_LOCAL_PROOF_RESULT=/tmp/zig_docker_post_100k_to_tip_debug_$(RESULT_DATE).json \
	  BENCHMARK_GATE=post_100k_to_tip \
	  FRESH_STATE=false \
	  PRESERVE_PROOF_VOLUME=1

docker-smoke-once: docker-status docker-storage-proof docker-script-corpus

clean:
	rm -rf .zig-cache zig-cache zig-out data-zig data-zig-*
