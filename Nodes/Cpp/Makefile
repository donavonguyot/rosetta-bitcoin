DATA_DIR ?= ./data-cpp
PEERS ?= 127.0.0.1:48333
BUILD_DIR ?= build-core

DOCKER_COMPOSE ?= docker compose -f docker/docker-compose.yml
DOCKER_PROOF_VOLUME ?= cpbitnode_proof_data
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/cpp_rocksdb_codec_v2_storage.json
DOCKER_REBUILD ?= 0
DOCKER_BENCHMARK_RESULT ?= ../Shared/conformance/results/cpp_docker_supporting_5k_benchmark_$(shell date +%F).json
DOCKER_BENCHMARK_TARGET ?= 5000
DOCKER_BENCHMARK_BLOCKS_MAX ?= 5000
DOCKER_BENCHMARK_PEERS ?= host.docker.internal:48333
DOCKER_BENCHMARK_PREFETCH_DEPTH ?= 1
DOCKER_HEADERS_MAX ?= 200
DOCKER_BLOCKS_MAX ?= 2
DOCKER_SYNC_VOLUME ?= cpbitnode_sync_data
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5

.PHONY: build test docker-config docker-build docker-warm node-status sync-local cpp-node-storage-proof cpp-node-native-crypto-test docker-cpp-native-crypto-proof docker-cpp-supporting-5k-proof docker-cpp-rocksdb-storage-proof docker-cpp-sync-supervisor docker-cpp-sync-status docker-cpp-sync-stop docker-cpp-sync-resume clean

build:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(BUILD_DIR)

test:
	ctest --test-dir $(BUILD_DIR) --output-on-failure

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

cpp-node-native-crypto-test:
	cmake -S . -B $(BUILD_DIR)-native -DCMAKE_BUILD_TYPE=Release -DCPBITNODE_USE_ROCKSDB=ON -DCPBITNODE_USE_NATIVE_SECP256K1=ON
	cmake --build $(BUILD_DIR)-native
	ctest --test-dir $(BUILD_DIR)-native --output-on-failure

docker-cpp-native-crypto-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	$(DOCKER_COMPOSE) run --rm --no-deps cpbitnode-sync-proof cpbitnode_tests

docker-cpp-supporting-5k-proof:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) DOCKER_BENCHMARK_TARGET=$(DOCKER_BENCHMARK_TARGET) \
	  DOCKER_BENCHMARK_BLOCKS_MAX=$(DOCKER_BENCHMARK_BLOCKS_MAX) DOCKER_BENCHMARK_PEERS=$(DOCKER_BENCHMARK_PEERS) \
	  DOCKER_BENCHMARK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) DOCKER_BENCHMARK_RESULT=$(DOCKER_BENCHMARK_RESULT) \
	  scripts/docker_5k_benchmark.sh
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/cpbitnode.db

docker-cpp-rocksdb-storage-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build cpbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) PROOF_PATH=$(DOCKER_PROOF_PATH) \
	  $(DOCKER_COMPOSE) run --rm --no-deps cpbitnode-sync-proof \
	  cpbitnode-storage-proof --datadir /data --chainstate-backend rocksdb --proof-path /tmp/cpp_storage_proof.json
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/cpbitnode.db

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
