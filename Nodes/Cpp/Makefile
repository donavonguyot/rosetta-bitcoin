DATA_DIR ?= ./data-cpp
PEERS ?= 127.0.0.1:48333
BUILD_DIR ?= build-core
RESULT_DATE ?= $(shell date +%F)

DOCKER_COMPOSE ?= docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
DOCKER_BENCHMARK_PEERS ?= $(REFERENCE_P2P_PEER)
REFERENCE_P2P_CHECK_PEER = $(DOCKER_BENCHMARK_PEERS)
DOCKER_PROOF_VOLUME ?= cpbitnode_proof_data
POST_100K_TIP_VOLUME ?= cpbitnode_100k_proof_data
POST_100K_TIP_TARGET ?= $(or $(REFERENCE_FINISH_HEIGHT),100000)
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/cpp_rocksdb_codec_v2_storage.json
DOCKER_REBUILD ?= 0
BENCHMARK_DEBUG_DIR ?= .benchmark-results
DOCKER_BENCHMARK_RESULT ?= $(BENCHMARK_DEBUG_DIR)/cpp_docker_baseline_5k_benchmark_$(shell date +%F).json
DOCKER_10K_BENCHMARK_RESULT ?= ../Shared/conformance/results/cpp_docker_diagnostic_10k_benchmark_$(shell date +%F).json
DOCKER_50K_BENCHMARK_RESULT ?= $(BENCHMARK_DEBUG_DIR)/cpp_docker_shakedown_50k_benchmark_$(shell date +%F).json
DOCKER_100K_BENCHMARK_RESULT ?= $(BENCHMARK_DEBUG_DIR)/cpp_docker_performance_100k_benchmark_$(shell date +%F).json
SCRIPT_RESULT ?= ../Shared/conformance/results/cpp_script_corpus_$(shell date +%F).json
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/cpp_script_corpus_docker_$(shell date +%F).json
TESTING_RESULTS_DIR ?= ../Shared/testing/results
TESTING_CAPABILITY_EMITTER ?= python3 ../Shared/testing/tools/emit_crypto_capability_contract.py
CRYPTO_CAPABILITY_RESULT ?= $(TESTING_RESULTS_DIR)/cpp_crypto_vectors_$(RESULT_DATE).json
BLOCK_CONNECT_BACKEND_RESULT ?= $(TESTING_RESULTS_DIR)/cpp_block_connect_backend_$(RESULT_DATE).json
DOCKER_BENCHMARK_TARGET ?= 5000
DOCKER_BENCHMARK_BLOCKS_MAX ?= 5000
DOCKER_BENCHMARK_PREFETCH_DEPTH ?= 4
BENCHMARK_GATE ?= baseline_5k
DOCKER_HEADERS_MAX ?= 200
DOCKER_BLOCKS_MAX ?= 2
DOCKER_SYNC_VOLUME ?= cpbitnode_sync_data
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5

.PHONY: build test test-core test-wire test-runtime docker-config docker-build docker-warm node-status sync-local cpp-node-storage-proof cpp-node-script-corpus cpp-node-native-crypto-test docker-cpp-native-crypto-proof docker-cpp-supporting-5k-proof docker-cpp-supporting-10k-proof docker-cpp-supporting-50k-proof docker-cpp-primary-100k-proof docker-cpp-post-100k-to-tip-proof docker-proof-post-100k-to-tip docker-cpp-rocksdb-storage-proof docker-script-corpus docker-cpp-sync-supervisor docker-cpp-sync-status docker-cpp-sync-stop docker-cpp-sync-resume clean

build:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(BUILD_DIR)

test: build
	ctest --test-dir $(BUILD_DIR) --output-on-failure

test-core: build
	ctest --test-dir $(BUILD_DIR) -L core-regression --output-on-failure

test-wire: build
	ctest --test-dir $(BUILD_DIR) -L wire-codec --output-on-failure

test-runtime: build
	ctest --test-dir $(BUILD_DIR) -L runtime-smoke --output-on-failure

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build cpbitnode-sync-proof

docker-warm: docker-build

node-status:
	$(BUILD_DIR)/cpbitnode-db --datadir $(DATA_DIR) --chainstate-backend rocksdb

sync-local:
	$(BUILD_DIR)/cpbitnode-sync --datadir $(DATA_DIR) --chainstate-backend rocksdb --peers $(PEERS) --blocks-target $(or $(BLOCKS_TARGET),$(DOCKER_BLOCKS_MAX)) --blocks-max $(or $(BLOCKS_MAX),$(DOCKER_BLOCKS_MAX))

cpp-node-storage-proof:
	$(BUILD_DIR)/cpbitnode-storage-proof --datadir $(DATA_DIR) --chainstate-backend rocksdb --proof-path $(or $(PROOF_PATH),../Shared/conformance/results/cpp_rocksdb_codec_v2_storage.json)

cpp-node-script-corpus:
	$(BUILD_DIR)/cpbitnode-script-corpus --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json --result-path $(SCRIPT_RESULT)

cpp-node-native-crypto-test:
	cmake -S . -B $(BUILD_DIR)-native -DCMAKE_BUILD_TYPE=Release -DCPBITNODE_USE_ROCKSDB=ON -DCPBITNODE_USE_NATIVE_SECP256K1=ON
	cmake --build $(BUILD_DIR)-native
	ctest --test-dir $(BUILD_DIR)-native --output-on-failure

test-crypto-vectors:
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	cmake -S . -B $(BUILD_DIR)-native -DCMAKE_BUILD_TYPE=Release -DCPBITNODE_USE_ROCKSDB=ON -DCPBITNODE_USE_NATIVE_SECP256K1=ON >/dev/null; \
	cmake --build $(BUILD_DIR)-native >/dev/null; \
	if ctest --test-dir $(BUILD_DIR)-native -R cpp_core_regression --output-on-failure; then status=pass; passed_bip=19; passed_eq=27; notes="native CTest BIP340 CSV and crypto/backend vectors passed"; else status=fail; passed_bip=0; passed_eq=0; notes="native CTest BIP340 CSV or crypto/backend vectors failed"; fi; \
	printf '{"port":"cpp","backend":"libsecp256k1","outcomes":[{"capability":"crypto_bip340_vectors","status":"%s","case_passed":%s,"case_total":19,"notes":"%s"},{"capability":"crypto_libsecp256k1_equivalence","status":"%s","case_passed":%s,"case_total":27,"notes":"%s"}]}\n' "$$status" "$$passed_bip" "$$notes" "$$status" "$$passed_eq" "$$notes" > "$$tmp"; \
	$(TESTING_CAPABILITY_EMITTER) --outcomes "$$tmp" --result-path $(CRYPTO_CAPABILITY_RESULT)

test-block-connect-backend:
	@tmp=$$(mktemp); \
	trap 'rm -f "$$tmp"' EXIT; \
	cmake -S . -B $(BUILD_DIR)-native -DCMAKE_BUILD_TYPE=Release -DCPBITNODE_USE_ROCKSDB=ON -DCPBITNODE_USE_NATIVE_SECP256K1=ON >/dev/null; \
	cmake --build $(BUILD_DIR)-native >/dev/null; \
	if $(BUILD_DIR)-native/cpbitnode-script-corpus --result-path $(BUILD_DIR)-native/cpp_backend_probe_script_corpus.json >/dev/null; then status=pass; passed=2; notes="native script corpus passed, including backend probe fixtures"; else status=fail; passed=0; notes="native script corpus failed before backend probe fixtures could be claimed"; fi; \
	printf '{"port":"cpp","backend":"libsecp256k1","outcomes":[{"capability":"block_connect_with_backend","status":"%s","case_passed":%s,"case_total":2,"notes":"%s"}]}\n' "$$status" "$$passed" "$$notes" > "$$tmp"; \
	$(TESTING_CAPABILITY_EMITTER) --outcomes "$$tmp" --result-path $(BLOCK_CONNECT_BACKEND_RESULT)

docker-cpp-native-crypto-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	$(DOCKER_COMPOSE) run --rm --no-deps \
	  -v $(abspath $(RB_FIXTURE_SHARED)/conformance/fixtures):/Nodes/Shared/conformance/fixtures:ro \
	  cpbitnode-sync-proof cpbitnode_tests

docker-cpp-supporting-5k-proof:
	$(REFERENCE_P2P_CHECK)
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true; fi
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) DOCKER_BENCHMARK_TARGET=$(DOCKER_BENCHMARK_TARGET) \
	  DOCKER_BENCHMARK_BLOCKS_MAX=$(DOCKER_BENCHMARK_BLOCKS_MAX) DOCKER_BENCHMARK_PEERS=$(DOCKER_BENCHMARK_PEERS) \
	  DOCKER_BENCHMARK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) DOCKER_BENCHMARK_RESULT=$(DOCKER_BENCHMARK_RESULT) \
	  PRESERVE_PROOF_VOLUME=$(PRESERVE_PROOF_VOLUME) scripts/docker_5k_benchmark.sh

docker-cpp-supporting-10k-proof:
	$(MAKE) docker-cpp-supporting-5k-proof \
	  DOCKER_PROOF_VOLUME=cpbitnode_10k_proof_data \
	  DOCKER_BENCHMARK_RESULT=$(DOCKER_10K_BENCHMARK_RESULT) \
	  DOCKER_BENCHMARK_TARGET=10000 \
	  DOCKER_BENCHMARK_BLOCKS_MAX=10000 \
	  BENCHMARK_GATE=diagnostic_10k

docker-cpp-supporting-50k-proof:
	$(MAKE) docker-cpp-supporting-5k-proof \
	  DOCKER_PROOF_VOLUME=cpbitnode_50k_proof_data \
	  DOCKER_BENCHMARK_RESULT=$(DOCKER_50K_BENCHMARK_RESULT) \
	  DOCKER_BENCHMARK_TARGET=50000 \
	  DOCKER_BENCHMARK_BLOCKS_MAX=50000 \
	  BENCHMARK_GATE=shakedown_50k

docker-cpp-primary-100k-proof:
	$(MAKE) docker-cpp-supporting-5k-proof \
	  DOCKER_PROOF_VOLUME=cpbitnode_100k_proof_data \
	  DOCKER_BENCHMARK_RESULT=$(DOCKER_100K_BENCHMARK_RESULT) \
	  DOCKER_BENCHMARK_TARGET=100000 \
	  DOCKER_BENCHMARK_BLOCKS_MAX=100000 \
	  BENCHMARK_GATE=performance_100k

docker-cpp-post-100k-to-tip-proof:
	$(MAKE) docker-cpp-supporting-5k-proof \
	  DOCKER_PROOF_VOLUME=$(POST_100K_TIP_VOLUME) \
	  DOCKER_BENCHMARK_RESULT=$(BENCHMARK_DEBUG_DIR)/cpp_docker_post_100k_to_tip_debug_$(RESULT_DATE).json \
	  DOCKER_BENCHMARK_TARGET=$(POST_100K_TIP_TARGET) \
	  DOCKER_BENCHMARK_BLOCKS_MAX=$(POST_100K_TIP_TARGET) \
	  BENCHMARK_GATE=post_100k_to_tip \
	  PRESERVE_PROOF_VOLUME=1

docker-proof-post-100k-to-tip: docker-cpp-post-100k-to-tip-proof

docker-cpp-rocksdb-storage-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) PROOF_PATH=$(DOCKER_PROOF_PATH) \
	  $(DOCKER_COMPOSE) run --rm --no-deps cpbitnode-sync-proof \
	  cpbitnode-storage-proof --datadir /data --chainstate-backend rocksdb --proof-path /tmp/cpp_storage_proof.json

docker-script-corpus:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	$(DOCKER_COMPOSE) run --rm --no-deps \
	  -e CPBITNODE_REPO_ROOT=/shared \
	  -v $(abspath ../Shared/conformance):/shared/conformance -v $(RB_FIXTURE_SHARED)/conformance/fixtures:/shared/conformance/fixtures:ro \
	  cpbitnode-sync-proof cpbitnode-script-corpus \
	  --manifest /shared/conformance/fixtures/scripts/manifest.json \
	  --result-path $(DOCKER_SCRIPT_RESULT) \
	  --runtime-surface docker

docker-cpp-sync-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(PEERS) \
	  DOCKER_REBUILD=$(DOCKER_REBUILD) \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-cpp-sync-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps cpbitnode-sync-proof cpbitnode-db --datadir /data --chainstate-backend rocksdb

docker-cpp-sync-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.cpbitnode_supervisor_stop'

docker-cpp-sync-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.cpbitnode_supervisor_resume'

clean:
	rm -rf $(BUILD_DIR) $(BUILD_DIR)-native

include ../Shared/fixture_package.mk
build test test-core test-wire test-runtime docker-build cpp-node-script-corpus cpp-node-native-crypto-test test-crypto-vectors test-block-connect-backend docker-script-corpus: | fixture-package
