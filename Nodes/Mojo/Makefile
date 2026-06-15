SHELL := /bin/bash
include ../Shared/docker/reference_topology.mk

RESULT_DATE ?= $(shell date -u +%F)
DATA_DIR ?= ./data-mojo
PROOF_DATA_DIR ?= ./data-mojo-proof
BUILD_DIR ?= ./build
VENV_DIR ?= ./.venv
MOJO_VERSION ?= 1.0.0b1
MOJO ?= $(VENV_DIR)/bin/mojo
MOJO_VERSION_STAMP ?= $(VENV_DIR)/.mojo-version-$(MOJO_VERSION)
MOJO_BIN ?= $(BUILD_DIR)/mojobitnode
SHIM_EXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)
SHIM_FLAG := $(if $(filter Darwin,$(shell uname -s)),-dynamiclib,-shared)
SHIM_LIB ?= $(BUILD_DIR)/libmojobitnode_shim.$(SHIM_EXT)
MOJO_DOCS_DIR ?= ./.mojo-docs
MOJO_TOOLCHAIN_SMOKE ?= tests/toolchain_smoke.mojo
MOJO_SCRIPT_CORPUS_FOUNDATION_SMOKE ?= tests/script_corpus_foundation_smoke.mojo
MOJO_BLOCK_CORE_SMOKE ?= tests/block_core_smoke.mojo
UV ?= uv
PYTHON ?= /opt/homebrew/bin/python3.11
PKG_CONFIG ?= pkg-config
CRYPTO_VECTORS ?= ../Shared/conformance/fixtures/native_crypto_v1_vectors.json
HOST_CRYPTO_RESULT ?= /tmp/mojo_native_crypto_vectors_host_$(RESULT_DATE).json
HOST_STORAGE_RESULT ?= /tmp/mojo_rocksdb_storage_proof_host_$(RESULT_DATE).json
HOST_SCRIPT_CORPUS_DEV_RESULT ?= /tmp/mojo_script_corpus_dev_$(RESULT_DATE).json
SCRIPT_CORPUS_RESULT ?= ../Shared/conformance/results/mojo_script_corpus_$(RESULT_DATE).json
HOST_LOCAL_PROOF_RESULT ?= .benchmark-results/mojo_host_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= .benchmark-results/mojo_docker_baseline_5k_benchmark_$(RESULT_DATE).json
HOST_50K_PROOF_RESULT ?= .benchmark-results/mojo_host_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= .benchmark-results/mojo_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
FIXTURE_ID ?= scripts.bare_multisig_27840
FIXTURE_SET ?= all
DATA_VOLUME ?= mojobitnode_data
PROOF_VOLUME ?= mojobitnode_proof_data
PROOF_50K_VOLUME ?= mojobitnode_50k_proof_data
DOCKER_SYNC_TARGET ?= 5000
PROGRESS ?= 500
HOST_P2P_PEER ?= 127.0.0.1:48333
DOCKER_COMPOSE := docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml

.PHONY: host-deps-check host-deps-install host-setup host-mojo-version host-build host-warm host-status host-native-crypto-vectors host-storage-proof host-script-corpus-dev host-script-corpus host-local-reference-proof host-shakedown-50k-proof host-smoke-once host-toolchain-smoke host-script-corpus-foundation-smoke host-block-core-smoke
.PHONY: docker-config docker-build docker-mojo-version docker-warm docker-status docker-native-crypto-vectors docker-storage-proof docker-script-corpus docker-proof-local docker-proof-50k docker-smoke-once docker-toolchain-smoke
.PHONY: mojo-docs-cache mojo-docs-status clean

host-deps-check:
	@command -v brew >/dev/null || { echo "missing Homebrew; install brew first" >&2; exit 1; }
	@command -v $(UV) >/dev/null || { echo "missing uv; run 'brew install uv'" >&2; exit 1; }
	@test -x "$(PYTHON)" || { echo "missing $(PYTHON); run 'brew install python@3.11'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists rocksdb || { echo "missing rocksdb pkg-config metadata; run 'brew install rocksdb'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists libsecp256k1 || { echo "missing libsecp256k1 pkg-config metadata; run 'brew install secp256k1'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists openssl || { echo "missing OpenSSL pkg-config metadata; run 'brew install openssl@3'" >&2; exit 1; }

host-deps-install:
	brew install uv rocksdb secp256k1 pkgconf openssl@3 python@3.11

$(MOJO_VERSION_STAMP): | host-deps-check
	$(UV) venv $(VENV_DIR) --python $(PYTHON) --allow-existing
	$(UV) pip install --python $(VENV_DIR)/bin/python --prerelease allow --reinstall "mojo==$(MOJO_VERSION)"
	$(MOJO) --version
	@$(MOJO) --version | grep -q "$(MOJO_VERSION)" || { echo "expected Mojo $(MOJO_VERSION)" >&2; exit 1; }
	@touch $(MOJO_VERSION_STAMP)

host-setup: $(MOJO_VERSION_STAMP)

host-mojo-version: $(MOJO_VERSION_STAMP)
	@$(MOJO) --version
	@$(MOJO) --version | grep -q "$(MOJO_VERSION)" || { echo "expected Mojo $(MOJO_VERSION)" >&2; exit 1; }

$(SHIM_LIB): src/mojo_native_shim.c | host-deps-check
	mkdir -p $(BUILD_DIR)
	cc -O2 -Wall -Wextra -std=c11 -fPIC $(SHIM_FLAG) \
	  -o $(SHIM_LIB) \
	  src/mojo_native_shim.c \
	  $$($(PKG_CONFIG) --cflags --libs rocksdb libsecp256k1 openssl) \
	  -lstdc++

$(MOJO_BIN): src/mojobitnode.mojo src/block_core.mojo src/script_corpus_foundation.mojo src/script_corpus_table.mojo $(MOJO_VERSION_STAMP) $(SHIM_LIB)
	$(MOJO) build -I src src/mojobitnode.mojo -o $(MOJO_BIN)

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

host-script-corpus-dev: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus-dev \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  $(if $(FIXTURE_ID),--fixture-id $(FIXTURE_ID),--fixture-set $(FIXTURE_SET)) \
	  --result-path $(HOST_SCRIPT_CORPUS_DEV_RESULT)); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"delegated":false' <<< "$$out"; \
	  test -s "$(HOST_SCRIPT_CORPUS_DEV_RESULT)"

host-script-corpus: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(SCRIPT_CORPUS_RESULT); \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"delegated":false' <<< "$$out"; \
	  grep -q '"fixture_count":45' <<< "$$out"; \
	  grep -q '"passed":45' <<< "$$out"; \
	  grep -q '"failed":0' <<< "$$out"; \
	  test -s "$(SCRIPT_CORPUS_RESULT)"

host-local-reference-proof: host-build
	@mkdir -p .benchmark-results
	@MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) local-reference-proof \
	  --datadir $(PROOF_DATA_DIR) \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(HOST_P2P_PEER) \
	  --progress $(PROGRESS) \
	  --result-path $(HOST_LOCAL_PROOF_RESULT)

host-shakedown-50k-proof:
	$(MAKE) host-local-reference-proof DOCKER_SYNC_TARGET=50000 HOST_LOCAL_PROOF_RESULT=$(HOST_50K_PROOF_RESULT) PROGRESS=$(PROGRESS)

host-smoke-once: host-build
	@MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) status --datadir $(DATA_DIR) --json >/tmp/mojo_status.json; \
	  grep -q '"entrypoint_language":"mojo"' /tmp/mojo_status.json; \
	  printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/mojo_status.json)"

host-toolchain-smoke: $(MOJO_VERSION_STAMP)
	$(MOJO) run $(MOJO_TOOLCHAIN_SMOKE)

host-script-corpus-foundation-smoke: $(MOJO_VERSION_STAMP)
	$(MOJO) run -I src $(MOJO_SCRIPT_CORPUS_FOUNDATION_SMOKE)

host-block-core-smoke: host-build
	MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO) run -I src $(MOJO_BLOCK_CORE_SMOKE)

mojo-docs-cache:
	$(PYTHON) scripts/cache_mojo_docs.py --output-dir $(MOJO_DOCS_DIR)

mojo-docs-status:
	@test -s "$(MOJO_DOCS_DIR)/llms.txt" || { echo "missing $(MOJO_DOCS_DIR)/llms.txt; run 'make mojo-docs-cache'" >&2; exit 1; }
	@test -s "$(MOJO_DOCS_DIR)/stdlib-parallelize-function.md" || { echo "missing $(MOJO_DOCS_DIR)/stdlib-parallelize-function.md; run 'make mojo-docs-cache'" >&2; exit 1; }
	@test -s "$(MOJO_DOCS_DIR)/stdlib-sync-parallelize.md" || { echo "missing $(MOJO_DOCS_DIR)/stdlib-sync-parallelize.md; run 'make mojo-docs-cache'" >&2; exit 1; }
	@test -s "$(MOJO_DOCS_DIR)/stdlib-asyncrt-task-group.md" || { echo "missing $(MOJO_DOCS_DIR)/stdlib-asyncrt-task-group.md; run 'make mojo-docs-cache'" >&2; exit 1; }
	@test -s "$(MOJO_DOCS_DIR)/stdlib-atomic.md" || { echo "missing $(MOJO_DOCS_DIR)/stdlib-atomic.md; run 'make mojo-docs-cache'" >&2; exit 1; }
	@test -s "$(MOJO_DOCS_DIR)/stdlib-lock-blocking-spin-lock.md" || { echo "missing $(MOJO_DOCS_DIR)/stdlib-lock-blocking-spin-lock.md; run 'make mojo-docs-cache'" >&2; exit 1; }
	@$(PYTHON) -c 'import json; from pathlib import Path; manifest = json.loads(Path("$(MOJO_DOCS_DIR)/manifest.json").read_text()); print("mojo_docs_cache fetched_at={} files={}".format(manifest["fetched_at"], len(manifest["files"])))'

docker-config:
	$(DOCKER_COMPOSE) config >/dev/null

docker-build:
	$(DOCKER_COMPOSE) build mojobitnode

docker-mojo-version:
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /opt/mojo/bin/mojo mojobitnode --version); \
	  echo "$$out"; \
	  grep -q "$(MOJO_VERSION)" <<< "$$out" || { echo "expected Mojo $(MOJO_VERSION)" >&2; exit 1; }

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

docker-script-corpus:
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode script-corpus \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(SCRIPT_CORPUS_RESULT); \
	  grep -q '"runtime_surface":"docker"' <<< "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"delegated":false' <<< "$$out"; \
	  grep -q '"fixture_count":45' <<< "$$out"; \
	  grep -q '"passed":45' <<< "$$out"; \
	  grep -q '"failed":0' <<< "$$out"; \
	  test -s "$(SCRIPT_CORPUS_RESULT)"

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@mkdir -p .benchmark-results
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then docker volume rm -f $(PROOF_VOLUME) docker_$(PROOF_VOLUME) >/dev/null 2>&1 || true; fi
	DOCKER_DATA_VOLUME=$(PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e REFERENCE_P2P_PEER=$(DOCKER_P2P_PEER) \
	  mojobitnode local-reference-proof \
	  --datadir /data \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --progress $(PROGRESS) \
	  --result-path /benchmark-results/$(notdir $(DOCKER_LOCAL_PROOF_RESULT))

docker-proof-50k:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PROOF_50K_VOLUME) DOCKER_SYNC_TARGET=50000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT) PROGRESS=$(PROGRESS)

docker-smoke-once:
	@out=$$(DOCKER_DATA_VOLUME=$(DATA_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /bin/sh mojobitnode -lc 'mojobitnode status --datadir /data --json >/tmp/status.json && printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/status.json)"'); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-toolchain-smoke:
	$(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /opt/mojo/bin/mojo mojobitnode run /usr/local/share/mojobitnode/tests/toolchain_smoke.mojo

clean:
	rm -rf data-mojo data-mojo-proof build .venv .benchmark-results .mojo-docs
