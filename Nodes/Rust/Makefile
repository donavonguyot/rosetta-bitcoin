CARGO ?= cargo
DATA_DIR ?= ./data-rust
SYNC_DATA_DIR ?= ./data-rust-sync-10k
PROOF_DATA_DIR ?= ./data-rust-proof
LOCAL_REFERENCE_DATA_DIR ?= ./data-rust-local-reference
SYNC_TARGET ?= 10000
CONNECT_TARGET ?= $(SYNC_TARGET)
RPC_URL ?= http://127.0.0.1:48332
RPC_USER ?= rosetta
RPC_PASSWORD ?= rosetta-dev-only
RPC_RETRIES ?= 10
PREFETCH_DEPTH ?= 8
PROGRESS ?= 100
RESULT_DATE ?= $(shell date +%F)
STORAGE_RESULT ?= ../../NodeCore/conformance/results/rust_storage_gate_$(RESULT_DATE).json
SCRIPT_RESULT ?= ../../NodeCore/conformance/results/rust_script_corpus_$(RESULT_DATE).json
LOCAL_REFERENCE_RESULT ?= ../../NodeCore/conformance/results/rust_local_reference_docker_sync_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml

.PHONY: build test rust-node-status rust-node-storage-proof rust-node-codec-vectors rust-node-native-crypto-vectors rust-node-script-corpus rust-node-sync-local rust-node-connect-local rust-node-local-reference-proof rust-node-local-reference-proof-fast docker-config docker-build docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-local-fast docker-smoke-once clean

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
	RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) $(CARGO) run -- local-reference-proof --datadir $(LOCAL_REFERENCE_DATA_DIR) --target $(SYNC_TARGET) --rpc-url $(RPC_URL) --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path $(LOCAL_REFERENCE_RESULT)

rust-node-local-reference-proof-fast:
	RSBITNODE_ROCKSDB_DISABLE_WAL=1 RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) $(CARGO) run -- local-reference-proof --datadir $(LOCAL_REFERENCE_DATA_DIR)-fast --target $(SYNC_TARGET) --rpc-url $(RPC_URL) --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path ../../NodeCore/conformance/results/rust_local_reference_docker_sync_fast_$(RESULT_DATE).json

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode rsbitnode status --datadir /data --runtime-surface docker

docker-storage-proof:
	@docker volume rm -f rsbitnode_proof_data docker_rsbitnode_proof_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-proof rsbitnode storage-proof --datadir /data --result-path /results/rust_storage_gate_docker_$(RESULT_DATE).json --runtime-surface docker

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-script-corpus rsbitnode script-corpus --manifest /workspace/NodeCore/conformance/fixtures/scripts/manifest.json --result-path /results/rust_script_corpus_docker_$(RESULT_DATE).json --runtime-surface docker

docker-proof-local:
	@docker volume rm -f rsbitnode_local_reference_data docker_rsbitnode_local_reference_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_RPC_RETRIES=$(RPC_RETRIES) -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --rpc-url http://host.docker.internal:48332 --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path /results/rust_local_reference_docker_sync_$(RESULT_DATE).json --runtime-surface docker

docker-proof-local-fast:
	@docker volume rm -f rsbitnode_local_reference_data docker_rsbitnode_local_reference_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_ROCKSDB_DISABLE_WAL=1 -e RSBITNODE_RPC_RETRIES=$(RPC_RETRIES) -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --rpc-url http://host.docker.internal:48332 --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD) --progress $(PROGRESS) --result-path /results/rust_local_reference_docker_sync_fast_$(RESULT_DATE).json --runtime-surface docker

docker-smoke-once:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-supervisor

clean:
	rm -rf data-rust data-rust-proof target
