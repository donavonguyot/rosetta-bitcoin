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
BENCHMARK_GATE ?= baseline_5k
RESULT_DATE ?= $(shell date +%F)
STORAGE_RESULT ?= ../Shared/conformance/results/rust_storage_gate_$(RESULT_DATE).json
SCRIPT_RESULT ?= ../Shared/conformance/results/rust_script_corpus_$(RESULT_DATE).json
TESTING_RESULTS_DIR ?= ../Shared/testing/results
TESTING_CAPABILITY_EMITTER ?= python3 ../Shared/testing/tools/emit_crypto_capability_contract.py
CRYPTO_CAPABILITY_RESULT ?= $(TESTING_RESULTS_DIR)/rust_crypto_vectors_$(RESULT_DATE).json
BLOCK_CONNECT_BACKEND_RESULT ?= $(TESTING_RESULTS_DIR)/rust_block_connect_backend_$(RESULT_DATE).json
BENCHMARK_DEBUG_DIR ?= .benchmark-results
LOCAL_REFERENCE_RESULT ?= $(BENCHMARK_DEBUG_DIR)/rust_docker_baseline_5k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_10K_RESULT ?= ../Shared/conformance/results/rust_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_50K_RESULT ?= $(BENCHMARK_DEBUG_DIR)/rust_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_100K_RESULT ?= $(BENCHMARK_DEBUG_DIR)/rust_docker_performance_100k_benchmark_$(RESULT_DATE).json
LOCAL_REFERENCE_TUNING_100K_RESULT ?= ../Shared/conformance/results/rust_docker_tuning_50k_to_100k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_RESULT ?= /tmp/rust_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_10K_RESULT ?= /results/rust_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_50K_RESULT ?= /tmp/rust_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_100K_RESULT ?= /tmp/rust_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_REFERENCE_TUNING_100K_RESULT ?= /results/rust_docker_tuning_50k_to_100k_benchmark_$(RESULT_DATE).json
RPC_REPLAY_RESULT ?= ../Shared/conformance/results/rust_local_reference_docker_sync_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
DOCKER_REBUILD ?= 0
DOCKER_LOCAL_PROOF_VOLUME ?= rsbitnode_proof_data
POST_100K_TIP_VOLUME ?= rsbitnode_post_100k_to_tip_data
POST_100K_TIP_TARGET ?= $(or $(REFERENCE_FINISH_HEIGHT),100000)
DOCKER_TUNING_SOURCE_VOLUME ?= rsbitnode_50k_proof_data
DOCKER_TUNING_100K_VOLUME ?= rsbitnode_tuning_50k_to_100k_data
TUNING_SOURCE_50K_ARTIFACT ?= ../Shared/conformance/results/rust_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_EXTERNAL_P2P_PEER ?=
DOCKER_EXTERNAL_PROBE_VOLUME ?= rsbitnode_external_5k_probe_data

.PHONY: build test rust-node-status rust-node-storage-proof rust-node-codec-vectors rust-node-native-crypto-vectors rust-node-script-corpus rust-node-sync-local rust-node-connect-local rust-node-local-reference-proof rust-node-local-reference-proof-fast docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-proof-post-100k-to-tip docker-tuning-100k-from-50k docker-proof-rpc-replay docker-probe-external docker-proof-local-fast docker-smoke-once clean

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

test-crypto-vectors:
	$(TESTING_CAPABILITY_EMITTER) crypto-vectors --port rust --backend rust-secp256k1 --result-path $(CRYPTO_CAPABILITY_RESULT)

test-block-connect-backend:
	$(TESTING_CAPABILITY_EMITTER) block-connect-backend --port rust --backend rust-secp256k1 --result-path $(BLOCK_CONNECT_BACKEND_RESULT)

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
	$(REFERENCE_P2P_CHECK)
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then docker volume rm -f $(DOCKER_LOCAL_PROOF_VOLUME) docker_$(DOCKER_LOCAL_PROOF_VOLUME) >/dev/null 2>&1 || true; fi
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_LOCAL_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --byte-source p2p --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_LOCAL_REFERENCE_RESULT) --runtime-surface docker

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_10k_proof_data \
	  SYNC_TARGET=10000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_10K_RESULT) \
	  BENCHMARK_GATE=diagnostic_10k

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_50k_proof_data \
	  SYNC_TARGET=50000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_50K_RESULT) \
	  BENCHMARK_GATE=shakedown_50k

docker-proof-100k:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=rsbitnode_100k_proof_data \
	  SYNC_TARGET=100000 \
	  DOCKER_LOCAL_REFERENCE_RESULT=$(DOCKER_LOCAL_REFERENCE_100K_RESULT) \
	  BENCHMARK_GATE=performance_100k

docker-proof-post-100k-to-tip:
	$(MAKE) docker-proof-local \
	  DOCKER_LOCAL_PROOF_VOLUME=$(POST_100K_TIP_VOLUME) \
	  SYNC_TARGET=$(POST_100K_TIP_TARGET) \
	  DOCKER_LOCAL_REFERENCE_RESULT=/tmp/rust_docker_post_100k_to_tip_debug_$(RESULT_DATE).json \
	  BENCHMARK_GATE=post_100k_to_tip \
	  PRESERVE_PROOF_VOLUME=1

docker-tuning-100k-from-50k:
	$(REFERENCE_P2P_CHECK)
	@test -f "$(TUNING_SOURCE_50K_ARTIFACT)" || { echo "error: missing source 50k artifact: $(TUNING_SOURCE_50K_ARTIFACT)" >&2; exit 1; }
	@python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); e={"result":"passed","benchmark_lane":"shakedown_50k_p2p","validated_height":50000,"validated_hash":"00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb","chainstate_utxo_count":568855,"utxo_accounting_policy":"core_spendable_v1"}; bad=[f"{k}={d.get(k)!r}" for k,v in e.items() if d.get(k)!=v]; sys.exit("source 50k artifact is not certified: "+", ".join(bad)) if bad else None' "$(TUNING_SOURCE_50K_ARTIFACT)"
	@source_volume="$(DOCKER_TUNING_SOURCE_VOLUME)"; \
	  if ! docker volume inspect "$$source_volume" >/dev/null 2>&1; then source_volume="docker_$(DOCKER_TUNING_SOURCE_VOLUME)"; fi; \
	  docker volume inspect "$$source_volume" >/dev/null; \
	  docker volume rm -f $(DOCKER_TUNING_100K_VOLUME) docker_$(DOCKER_TUNING_100K_VOLUME) >/dev/null 2>&1 || true; \
	  docker volume create docker_$(DOCKER_TUNING_100K_VOLUME) >/dev/null; \
	  docker run --rm -v "$$source_volume":/source:ro -v docker_$(DOCKER_TUNING_100K_VOLUME):/target alpine:3.20 sh -c 'cd /source && tar cf - . | tar xf - -C /target'
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_TUNING_100K_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e RSBITNODE_BLOCK_PREFETCH_DEPTH=$(PREFETCH_DEPTH) \
	  -e RSBITNODE_BENCHMARK_GATE=tuning_50k_to_100k \
	  -e RSBITNODE_BENCHMARK_KIND=tuning_50k_to_100k_p2p \
	  -e RSBITNODE_BENCHMARK_LANE=tuning_50k_to_100k_p2p \
	  -e 'RSBITNODE_TARGET_LABEL=50k->100k' \
	  -e RSBITNODE_FRESH_STATE=false \
	  -e RSBITNODE_SOURCE_GATE=shakedown_50k \
	  -e RSBITNODE_SOURCE_BENCHMARK_LANE=shakedown_50k_p2p \
	  -e RSBITNODE_SOURCE_VALIDATED_HEIGHT=50000 \
	  -e RSBITNODE_SOURCE_HEADER_HEIGHT=50000 \
	  -e RSBITNODE_SOURCE_VALIDATED_HASH=00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb \
	  -e RSBITNODE_SOURCE_CHAINSTATE_UTXO_COUNT=568855 \
	  -e RSBITNODE_SOURCE_UTXO_ACCOUNTING_POLICY=core_spendable_v1 \
	  -e RSBITNODE_SOURCE_ARTIFACT_PATH=$(TUNING_SOURCE_50K_ARTIFACT) \
	  -e RSBITNODE_SOURCE_ARTIFACT_SHA256="$$(shasum -a 256 "$(TUNING_SOURCE_50K_ARTIFACT)" | awk '{print $$1}')" \
	  -e RSBITNODE_SOURCE_DOCKER_VOLUME=$(DOCKER_TUNING_SOURCE_VOLUME) \
	  -e RSBITNODE_RESTORED_DOCKER_VOLUME=$(DOCKER_TUNING_100K_VOLUME) \
	  rsbitnode-local-reference-proof rsbitnode local-reference-proof --datadir /data --target 100000 --byte-source p2p --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_LOCAL_REFERENCE_TUNING_100K_RESULT) --runtime-surface docker

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
