SHELL := /bin/bash

RESULT_DATE ?= $(shell date -u +%F)
DATA_DIR ?= ./data-mojo
PROOF_DATA_DIR ?= ./data-mojo-proof
BUILD_DIR ?= ./build
VENV_DIR ?= ./.venv
MOJO ?= $(VENV_DIR)/bin/mojo
MOJO_BIN ?= $(BUILD_DIR)/mojobitnode
SHIM_EXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)
SHIM_FLAG := $(if $(filter Darwin,$(shell uname -s)),-dynamiclib,-shared)
SHIM_LIB ?= $(BUILD_DIR)/libmojobitnode_shim.$(SHIM_EXT)
UV ?= uv
PYTHON ?= /opt/homebrew/bin/python3.11
PKG_CONFIG ?= pkg-config
CRYPTO_VECTORS ?= ../Shared/conformance/fixtures/native_crypto_v1_vectors.json
HOST_CRYPTO_RESULT ?= /tmp/mojo_native_crypto_vectors_host_$(RESULT_DATE).json
HOST_STORAGE_RESULT ?= /tmp/mojo_rocksdb_storage_proof_host_$(RESULT_DATE).json
DATA_VOLUME ?= mojobitnode_data
PROOF_VOLUME ?= mojobitnode_proof_data
DOCKER_COMPOSE := docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml

.PHONY: host-deps-check host-deps-install host-setup host-build host-warm host-status host-native-crypto-vectors host-storage-proof host-smoke-once
.PHONY: docker-config docker-build docker-warm docker-status docker-native-crypto-vectors docker-storage-proof docker-smoke-once clean

host-deps-check:
	@command -v brew >/dev/null || { echo "missing Homebrew; install brew first" >&2; exit 1; }
	@command -v $(UV) >/dev/null || { echo "missing uv; run 'brew install uv'" >&2; exit 1; }
	@test -x "$(PYTHON)" || { echo "missing $(PYTHON); run 'brew install python@3.11'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists rocksdb || { echo "missing rocksdb pkg-config metadata; run 'brew install rocksdb'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists libsecp256k1 || { echo "missing libsecp256k1 pkg-config metadata; run 'brew install secp256k1'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists openssl || { echo "missing OpenSSL pkg-config metadata; run 'brew install openssl@3'" >&2; exit 1; }

host-deps-install:
	brew install uv rocksdb secp256k1 pkgconf openssl@3 python@3.11

$(MOJO): | host-deps-check
	$(UV) venv $(VENV_DIR) --python $(PYTHON)
	$(UV) pip install --python $(VENV_DIR)/bin/python mojo
	$(MOJO) --version

host-setup: $(MOJO)

$(SHIM_LIB): src/mojo_native_shim.c | host-deps-check
	mkdir -p $(BUILD_DIR)
	cc -O2 -Wall -Wextra -std=c11 -fPIC $(SHIM_FLAG) \
	  -o $(SHIM_LIB) \
	  src/mojo_native_shim.c \
	  $$($(PKG_CONFIG) --cflags --libs rocksdb libsecp256k1 openssl) \
	  -lstdc++

$(MOJO_BIN): src/mojobitnode.mojo $(MOJO) $(SHIM_LIB)
	$(MOJO) build src/mojobitnode.mojo -o $(MOJO_BIN)

host-build: host-deps-check $(MOJO_BIN)

host-warm: host-build

host-status: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) status --datadir $(DATA_DIR) --json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

host-native-crypto-vectors: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) native-crypto-vectors \
	  --vectors $(CRYPTO_VECTORS) \
	  --result-path $(HOST_CRYPTO_RESULT)); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"case_total":8' <<< "$$out"

host-storage-proof: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) storage-proof \
	  --datadir $(PROOF_DATA_DIR) \
	  --result-path $(HOST_STORAGE_RESULT)); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

host-smoke-once: host-build
	@MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) status --datadir $(DATA_DIR) --json >/tmp/mojo_status.json; \
	  grep -q '"entrypoint_language":"mojo"' /tmp/mojo_status.json; \
	  printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/mojo_status.json)"

docker-config:
	$(DOCKER_COMPOSE) config >/dev/null

docker-build:
	$(DOCKER_COMPOSE) build mojobitnode

docker-warm: docker-build

docker-status:
	@out=$$(DOCKER_DATA_VOLUME=$(DATA_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps mojobitnode status --datadir /data --json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-native-crypto-vectors:
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode native-crypto-vectors \
	  --vectors /workspace/Shared/conformance/fixtures/native_crypto_v1_vectors.json \
	  --result-path /tmp/mojo_native_crypto_vectors_$(RESULT_DATE).json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"case_total":8' <<< "$$out"

docker-storage-proof:
	@out=$$(DOCKER_PROOF_VOLUME=$(PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps mojobitnode storage-proof \
	  --datadir /data \
	  --result-path /tmp/mojo_rocksdb_storage_proof_$(RESULT_DATE).json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-smoke-once:
	@out=$$(DOCKER_DATA_VOLUME=$(DATA_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /bin/sh mojobitnode -lc 'mojobitnode status --datadir /data --json >/tmp/status.json && printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/status.json)"'); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

clean:
	rm -rf data-mojo data-mojo-proof build .venv .benchmark-results
