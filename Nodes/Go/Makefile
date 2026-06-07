GO ?= go
DATA_DIR ?= ./data-go
PROOF_DATA_DIR ?= ./data-go-proof
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/go_script_corpus_$(RESULT_DATE).json
STORAGE_RESULT ?= ../Shared/conformance/results/go_storage_gate_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/go_script_corpus_docker_$(RESULT_DATE).json
DOCKER_STORAGE_RESULT ?= /results/go_storage_gate_docker_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /results/go_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_PROOF_RESULT ?= /results/go_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= /results/go_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_100K_PROOF_RESULT ?= /results/go_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_RPC_REPLAY_RESULT ?= /results/go_local_reference_docker_sync_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py
DOCKER_PROOF_VOLUME ?= gobitnode_proof_data
DOCKER_RPC_REPLAY_VOLUME ?= gobitnode_local_reference_proof_data
DOCKER_SYNC_VOLUME ?= gobitnode_sync_data
DOCKER_REBUILD ?= 0
DOCKER_BENCHMARK_PREFETCH_DEPTH ?= 4
DOCKER_BENCHMARK_PROGRESS ?= 250

SYNC_TARGET ?= 10000
CONNECT_TARGET ?= 2
RPC_URL ?= http://127.0.0.1:48332
RPC_USER ?= rosetta
RPC_PASSWORD ?= rosetta-dev-only
DOCKER_SYNC_TARGET ?= 5000
DOCKER_RPC_URL ?= http://host.docker.internal:48332
BENCHMARK_GATE ?= baseline_5k

.PHONY: build test go-node-status go-node-storage-proof go-node-script-corpus go-node-sync-local go-node-connect-local go-node-native-crypto-test docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-proof-100k docker-proof-rpc-replay docker-smoke-once clean

build:
	$(GO) build ./cmd/...

test:
	$(GO) test ./...

go-node-status:
	$(GO) run ./cmd/gobitnode-status --datadir $(DATA_DIR)

go-node-storage-proof:
	$(GO) run ./cmd/gobitnode-storage-proof --datadir $(PROOF_DATA_DIR) --result-path $(STORAGE_RESULT)

go-node-script-corpus:
	$(GO) run ./cmd/gobitnode-script-corpus --result-path $(SCRIPT_RESULT)

go-node-sync-local:
	$(GO) run ./cmd/gobitnode-sync --datadir $(DATA_DIR) --target $(SYNC_TARGET) --rpc-url $(RPC_URL) --rpc-user $(RPC_USER) --rpc-password $(RPC_PASSWORD)

go-node-connect-local:
	$(GO) run ./cmd/gobitnode-connect --datadir $(DATA_DIR) --target $(CONNECT_TARGET)

go-node-native-crypto-test:
	$(GO) test ./internal/crypto -run TestNativeCryptoAvailable

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build gobitnode

docker-warm: docker-build

docker-status:
	GOBITNODE_RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps gobitnode gobitnode status --datadir /data

docker-storage-proof:
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) GOBITNODE_RUNTIME_SURFACE=docker \
	  $(DOCKER_COMPOSE) run --rm --no-deps gobitnode-proof \
	  gobitnode storage-proof --datadir /data --result-path $(DOCKER_STORAGE_RESULT)

docker-script-corpus:
	GOBITNODE_RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps gobitnode-script-corpus \
	  gobitnode script-corpus \
	  --manifest /shared/conformance/fixtures/scripts/manifest.json \
	  --result-path $(DOCKER_SCRIPT_RESULT)

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) GOBITNODE_RUNTIME_SURFACE=docker \
	  GOBITNODE_PAR_SCRIPT_VERIFY=1 GOBITNODE_BLOCK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) GOBITNODE_ROCKSDB_BLOCK_CACHE_MB=512 \
	  $(DOCKER_COMPOSE) run --rm gobitnode-local-reference-proof \
	  gobitnode local-reference-proof \
	  --datadir /data \
	  --target $(DOCKER_SYNC_TARGET) \
	  --progress $(DOCKER_BENCHMARK_PROGRESS) \
	  --byte-source p2p \
		  --peer $(DOCKER_P2P_PEER) \
		  --result-path $(DOCKER_LOCAL_PROOF_RESULT)
	@if [ "$(BENCHMARK_GATE)" != "diagnostic_10k" ]; then \
	  $(VALIDATE_BENCHMARK_ARTIFACT) --gate $(BENCHMARK_GATE) --artifact $(patsubst /results/%,../Shared/conformance/results/%,$(DOCKER_LOCAL_PROOF_RESULT)) --port go --strict-current; \
	fi

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=gobitnode_10k_proof_data \
	  DOCKER_SYNC_TARGET=10000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_10K_PROOF_RESULT) \
	  BENCHMARK_GATE=diagnostic_10k

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=gobitnode_50k_proof_data \
	  DOCKER_SYNC_TARGET=50000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT) \
	  BENCHMARK_GATE=shakedown_50k

docker-proof-100k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=gobitnode_100k_proof_data \
	  DOCKER_SYNC_TARGET=100000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_100K_PROOF_RESULT) \
	  BENCHMARK_GATE=performance_100k

docker-proof-rpc-replay:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48332 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core RPC port 48332 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f $(DOCKER_RPC_REPLAY_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_RPC_REPLAY_VOLUME) GOBITNODE_RUNTIME_SURFACE=docker \
	  GOBITNODE_PAR_SCRIPT_VERIFY=1 GOBITNODE_BLOCK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) GOBITNODE_ROCKSDB_BLOCK_CACHE_MB=512 \
	  $(DOCKER_COMPOSE) run --rm gobitnode-local-reference-proof \
	  gobitnode local-reference-proof \
	  --datadir /data \
	  --target $(DOCKER_SYNC_TARGET) \
	  --byte-source rpc \
	  --rpc-url $(DOCKER_RPC_URL) \
	  --rpc-user $(RPC_USER) \
	  --rpc-password $(RPC_PASSWORD) \
	  --result-path $(DOCKER_RPC_REPLAY_RESULT)

docker-smoke-once:
	DOCKER_SYNC_VOLUME=$(DOCKER_SYNC_VOLUME) GOBITNODE_RUNTIME_SURFACE=supervisor $(DOCKER_COMPOSE) run --rm --no-deps gobitnode-supervisor

clean:
	rm -rf data-go data-go-proof bin
