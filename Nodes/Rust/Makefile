CARGO ?= cargo
DATA_DIR ?= ./data-rust
SYNC_DATA_DIR ?= ./data-rust-sync-10k
PROOF_DATA_DIR ?= ./data-rust-proof
LOCAL_REFERENCE_DATA_DIR ?= ./data-rust-local-reference
SYNC_TARGET ?= 5000
CONNECT_TARGET ?= $(SYNC_TARGET)
RPC_URL ?= http://127.0.0.1:48332
RPC_USER ?= rosetta
RPC_PASSWORD ?= rosetta-dev-only
RPC_RETRIES ?= 10
PREFETCH_DEPTH ?= 4
PROGRESS ?= 100
RESULT_DATE ?= $(shell date +%F)
STORAGE_RESULT ?= ../Shared/conformance/results/rust_storage_gate_$(RESULT_DATE).json
SCRIPT_RESULT ?= ../Shared/conformance/results/rust_script_corpus_$(RESULT_DATE).json
LOCAL_REFERENCE_RESULT ?= ../Shared/conformance/results/rust_docker_supporting_5k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_10K_RESULT ?= ../Shared/conformance/results/rust_docker_supporting_10k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_50K_RESULT ?= ../Shared/conformance/results/rust_docker_supporting_50k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_100K_RESULT ?= ../Shared/conformance/results/rust_docker_primary_100k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_RESULT ?= /results/rust_docker_supporting_5k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_10K_RESULT ?= /results/rust_docker_supporting_10k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_50K_RESULT ?= /results/rust_docker_supporting_50k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_100K_RESULT ?= /results/rust_docker_primary_100k_benchmark_$(RESULT_DATE).json
RPC_REPLAY_RESULT ?= ../Shared/conformance/results/rust_local_reference_docker_sync_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_REBUILD ?= 0
DOCKER_P2P_PEER ?= host.docker.internal:48333
DOCKER_LOCAL_PROOF_VOLUME ?= rsbitnode_proof_data
DOCKER_EXTERNAL_P2P_PEER ?=
DOCKER_EXTERNAL_PROBE_VOLUME ?= rsbitnode_external_5k_probe_data

.PHONY: build test rust-node-status rust-node-storage-proof rust-node-codec-vectors rust-node-native-crypto-vectors rust-node-script-corpus rust-node-sync-local rust-node-connect-local rust-node-local-reference-proof rust-node-local-reference-proof-fast docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-proof-rpc-replay docker-probe-external docker-proof-local-fast docker-smoke-once clean

build:
	$(CARGO) build

test:
	$(CARGO) test

rust-node-status:
	$(CARGO) run -- status --datadir $(DATA_DIR)

rust-node-storage-proof:
	$(CARGO) run -- storage-proof --datadir $(PROOF_DATA_DIR) --result-path $(STORAGE_RESULT)

rust-node-codec-vectors:
	$(CARGO) run -- codec-vectors

rust-node-native-crypto-vectors:
	$(CARGO) run -- native-crypto-vectors

rust-node-script-corpus:
	$(CARGO) run -- script-corpus --result-path $(SCRIPT_RESULT)

rust-node-sync-local:
	$(CARGO) run -- sync --datadir $(SYNC_DATA_DIR) --target $(SYNC_TARGET) --rpc-url $(RPC_URL) --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD)

rust-node-connect-local:
	$(CARGO) run -- connect --datadir $(SYNC_DATA_DIR) --target $(CONNECT_TARGET)

rust-node-local-reference-proof:
	RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) $(CARGO) run -- local-reference-proof --datadir $(LOCAL_REFERENCE_DATA_DIR) --target $(SYNC_TARGET) --byte-source p2p --peer 127.0.0.1:48333 --progress $(PROGRESS) --result-path $(LOCAL_REFERENCE_RESULT)

rust-node-local-reference-proof-fast:
	RSBITNODE_ROCKSDB_DISABLE_WAL=1 RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) $(CARGO) run -- local-reference-proof --datadir $(LOCAL_REFERENCE_DATA_DIR)-fast --target $(SYNC_TARGET) --rpc-url $(RPC_URL) --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path ../Shared/conformance/results/rust_local_reference_docker_sync_fast_$(RESULT_DATE).json

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build

docker-warm: docker-build

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode rsbitnode status --datadir /data --runtime-surface docker

docker-storage-proof:
	@docker volume rm -f rsbitnode_proof_data docker_rsbitnode_proof_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-proof rsbitnode storage-proof --datadir /data --result-path /results/rust_storage_gate_docker_$(RESULT_DATE).json --runtime-surface docker

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-script-corpus rsbitnode script-corpus --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json --result-path /results/rust_script_corpus_docker_$(RESULT_DATE).json --runtime-surface docker

docker-proof-local:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f $(DOCKER_LOCAL_PROOF_VOLUME) docker_$(DOCKER_LOCAL_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_LOCAL_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --byte-source p2p --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_LOCAL_REFERENCE_RESULT) --runtime-surface docker

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_10k_proof_data \
	  SYNC_TARGET=10000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_10K_RESULT)

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_50k_proof_data \
	  SYNC_TARGET=50000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_50K_RESULT)

docker-proof-100k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_100k_proof_data \
	  SYNC_TARGET=100000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_100K_RESULT)

docker-proof-rpc-replay:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48332 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core RPC port 48332 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f rsbitnode_local_reference_data docker_rsbitnode_local_reference_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_RPC_RETRIES=$(RPC_RETRIES) -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --byte-source rpc --rpc-url http://host.docker.internal:48332 --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path /results/rust_local_reference_docker_sync_$(RESULT_DATE).json --runtime-surface docker

docker-probe-external:
	@[ -n "$(DOCKER_EXTERNAL_P2P_PEER)" ] || { echo "error: set DOCKER_EXTERNAL_P2P_PEER=<host:48333>" >&2; exit 1; }
	@docker volume rm -f $(DOCKER_EXTERNAL_PROBE_VOLUME) docker_$(DOCKER_EXTERNAL_PROBE_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_EXTERNAL_PROBE_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode external-peer-proof --datadir /data --target 5000 --peer $(DOCKER_EXTERNAL_P2P_PEER) --progress $(PROGRESS) --result-path /results/rust_docker_external_5k_probe_$(RESULT_DATE).json --runtime-surface docker

docker-proof-local-fast:
	@docker volume rm -f rsbitnode_local_reference_data docker_rsbitnode_local_reference_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_ROCKSDB_DISABLE_WAL=1 -e RSBITNODE_RPC_RETRIES=$(RPC_RETRIES) -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --rpc-url http://host.docker.internal:48332 --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path /results/rust_local_reference_docker_sync_fast_$(RESULT_DATE).json --runtime-surface docker

docker-smoke-once:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-supervisor

clean:
	rm -rf data-rust data-rust-proof target
