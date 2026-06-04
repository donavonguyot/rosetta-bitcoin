GO ?= go
DATA_DIR ?= ./data-go
PROOF_DATA_DIR ?= ./data-go-proof
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/go_script_corpus_$(RESULT_DATE).json
STORAGE_RESULT ?= ../Shared/conformance/results/go_storage_gate_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/go_script_corpus_docker_$(RESULT_DATE).json
DOCKER_STORAGE_RESULT ?= /results/go_storage_gate_docker_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /results/go_local_reference_docker_sync_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_PROOF_VOLUME ?= gobitnode_proof_data
DOCKER_LOCAL_PROOF_VOLUME ?= gobitnode_local_reference_proof_data
DOCKER_SYNC_VOLUME ?= gobitnode_sync_data

SYNC_TARGET ?= 10000
CONNECT_TARGET ?= 2
RPC_URL ?= http://127.0.0.1:48332
RPC_USER ?= rosetta
RPC_PASSWORD ?= rosetta-dev-only
DOCKER_SYNC_TARGET ?= 10000
DOCKER_RPC_URL ?= http://host.docker.internal:48332

.PHONY: build test go-node-status go-node-storage-proof go-node-script-corpus go-node-sync-local go-node-connect-local go-node-native-crypto-test docker-config docker-build docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-smoke-once clean

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
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48332 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core RPC port 48332 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f $(DOCKER_LOCAL_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_LOCAL_PROOF_VOLUME) GOBITNODE_RUNTIME_SURFACE=docker \
	  GOBITNODE_PAR_SCRIPT_VERIFY=1 GOBITNODE_ROCKSDB_BLOCK_CACHE_MB=512 \
	  $(DOCKER_COMPOSE) run --rm gobitnode-local-reference-proof \
	  gobitnode local-reference-proof \
	  --datadir /data \
	  --target $(DOCKER_SYNC_TARGET) \
	  --rpc-url $(DOCKER_RPC_URL) \
	  --rpc-user $(RPC_USER) \
	  --rpc-password $(RPC_PASSWORD) \
	  --result-path $(DOCKER_LOCAL_PROOF_RESULT)

docker-smoke-once:
	DOCKER_SYNC_VOLUME=$(DOCKER_SYNC_VOLUME) GOBITNODE_RUNTIME_SURFACE=supervisor $(DOCKER_COMPOSE) run --rm --no-deps gobitnode-supervisor

clean:
	rm -rf data-go data-go-proof bin
