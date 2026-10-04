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
MOJO_PARALLEL_RUNNER_SMOKE ?= tests/parallel_runner_smoke.mojo
MOJO_SCRIPT_CORPUS_FOUNDATION_SMOKE ?= tests/script_corpus_foundation_smoke.mojo
MOJO_BLOCK_CORE_SMOKE ?= tests/block_core_smoke.mojo
MOJO_NATIVE_BOUNDARY_AUDIT ?= scripts/native_boundary_audit.py
UV ?= uv
PYTHON ?= /opt/homebrew/bin/python3.11
PKG_CONFIG ?= pkg-config
CRYPTO_VECTORS ?= $(RB_FIXTURE_SHARED)/conformance/fixtures/native_crypto_v1_vectors.json
HOST_CRYPTO_RESULT ?= /tmp/mojo_native_crypto_vectors_host_$(RESULT_DATE).json
HOST_STORAGE_RESULT ?= /tmp/mojo_rocksdb_storage_proof_host_$(RESULT_DATE).json
HOST_SCRIPT_CORPUS_DEV_RESULT ?= /tmp/mojo_script_corpus_dev_$(RESULT_DATE).json
HOST_SCRIPT_CORPUS_SHADOW_RESULT ?= .benchmark-results/mojo_host_script_corpus_shadow_$(RESULT_DATE).json
DOCKER_SCRIPT_CORPUS_SHADOW_RESULT ?= .benchmark-results/mojo_docker_script_corpus_shadow_$(RESULT_DATE).json
HOST_SCRIPT_CORPUS_REJECT_NATIVE_RESULT ?= .benchmark-results/mojo_host_script_corpus_reject_native_$(RESULT_DATE).json
HOST_SCRIPT_CORPUS_REJECT_PURE_RESULT ?= .benchmark-results/mojo_host_script_corpus_reject_pure_$(RESULT_DATE).json
DOCKER_SCRIPT_CORPUS_REJECT_NATIVE_RESULT ?= .benchmark-results/mojo_docker_script_corpus_reject_native_$(RESULT_DATE).json
DOCKER_SCRIPT_CORPUS_REJECT_PURE_RESULT ?= .benchmark-results/mojo_docker_script_corpus_reject_pure_$(RESULT_DATE).json
HOST_PURE_CRYPTO_PROFILE_RESULT ?= .benchmark-results/mojo_host_pure_crypto_profile_$(RESULT_DATE).json
DOCKER_PURE_CRYPTO_PROFILE_RESULT ?= .benchmark-results/mojo_docker_pure_crypto_profile_$(RESULT_DATE).json
HOST_PURE_CRYPTO_MICROBENCH_RESULT ?= .benchmark-results/mojo_host_pure_crypto_microbench_$(RESULT_DATE).json
DOCKER_PURE_CRYPTO_MICROBENCH_RESULT ?= .benchmark-results/mojo_docker_pure_crypto_microbench_$(RESULT_DATE).json
PURE_CRYPTO_MICROBENCH_ITERS ?= 1000
PURE_CRYPTO_MICROBENCH_CASE ?= all
HOST_SHADOW_5K_PROOF_RESULT ?= .benchmark-results/mojo_host_shadow_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_SHADOW_5K_PROOF_RESULT ?= .benchmark-results/mojo_docker_shadow_baseline_5k_benchmark_$(RESULT_DATE).json
HOST_SHADOW_50K_PROOF_RESULT ?= .benchmark-results/mojo_host_shadow_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_SHADOW_50K_PROOF_RESULT ?= .benchmark-results/mojo_docker_shadow_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_SHADOW_100K_PROOF_RESULT ?= .benchmark-results/mojo_docker_shadow_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_SHADOW_POST_100K_TO_TIP_RESULT ?= .benchmark-results/mojo_docker_shadow_post_100k_to_tip_benchmark_$(RESULT_DATE).json
HOST_PURE_5K_PROOF_RESULT ?= .benchmark-results/mojo_host_pure_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_PURE_5K_PROOF_RESULT ?= .benchmark-results/mojo_docker_pure_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_PURE_100K_PROOF_RESULT ?= .benchmark-results/mojo_docker_pure_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_PURE_POST_100K_TO_TIP_RESULT ?= .benchmark-results/mojo_docker_pure_post_100k_to_tip_benchmark_$(RESULT_DATE).json
SCRIPT_CORPUS_RESULT ?= ../Shared/conformance/results/mojo_script_corpus_$(RESULT_DATE).json
HOST_LOCAL_PROOF_RESULT ?= .benchmark-results/mojo_host_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= .benchmark-results/mojo_docker_baseline_5k_benchmark_$(RESULT_DATE).json
HOST_50K_PROOF_RESULT ?= .benchmark-results/mojo_host_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= .benchmark-results/mojo_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_100K_PROOF_RESULT ?= .benchmark-results/mojo_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_POST_100K_TO_TIP_RESULT ?= .benchmark-results/mojo_docker_post_100k_to_tip_benchmark_$(RESULT_DATE).json
HOST_SHADOW_5K_DATA_DIR ?= ./data-mojo-shadow-5k-proof
HOST_SHADOW_50K_DATA_DIR ?= ./data-mojo-shadow-50k-proof
HOST_PURE_5K_DATA_DIR ?= ./data-mojo-pure-5k-proof
FIXTURE_ID ?= scripts.bare_multisig_27840
FIXTURE_SET ?= all
DATA_VOLUME ?= mojobitnode_data
PROOF_VOLUME ?= mojobitnode_proof_data
PROOF_50K_VOLUME ?= mojobitnode_50k_proof_data
PROOF_100K_VOLUME ?= mojobitnode_100k_proof_data
POST_100K_TIP_TARGET ?= $(or $(REFERENCE_FINISH_HEIGHT),100000)
SHADOW_5K_PROOF_VOLUME ?= mojobitnode_shadow_5k_proof_data
SHADOW_50K_PROOF_VOLUME ?= mojobitnode_shadow_50k_proof_data
SHADOW_100K_PROOF_VOLUME ?= mojobitnode_shadow_100k_proof_data
PURE_5K_PROOF_VOLUME ?= mojobitnode_pure_5k_proof_data
PURE_100K_PROOF_VOLUME ?= mojobitnode_pure_100k_proof_data
DOCKER_SYNC_TARGET ?= 5000
PROGRESS ?= 500
PROOF_EXTRA_ARGS ?=
MOJOBITNODE_PAR_SCRIPT_VERIFY ?= 0
MOJOBITNODE_SCRIPT_THREADS ?= 0
MOJOBITNODE_SCRIPT_MIN_INPUTS ?= 2
MOJOBITNODE_PROFILE_HOTPATH ?= 0
HOST_P2P_PEER ?= 127.0.0.1:48333
DOCKER_COMPOSE := docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml

.PHONY: host-deps-check host-deps-install host-setup host-mojo-version host-build host-warm host-status host-native-crypto-vectors host-pure-crypto-profile host-pure-crypto-microbench host-storage-proof host-script-corpus-dev host-script-corpus host-script-corpus-shadow host-script-corpus-reject host-script-corpus-reject-red host-local-reference-proof host-shakedown-50k-proof host-shadow-5k-proof host-shadow-50k-proof host-pure-5k-proof host-smoke-once host-toolchain-smoke host-parallel-runner-smoke host-script-corpus-foundation-smoke host-block-core-smoke host-native-boundary-audit
.PHONY: docker-config docker-build docker-mojo-version docker-warm docker-status docker-status-100k docker-status-shadow-100k docker-status-pure-100k docker-native-crypto-vectors docker-pure-crypto-profile docker-pure-crypto-microbench docker-storage-proof docker-script-corpus docker-script-corpus-shadow docker-script-corpus-reject docker-script-corpus-reject-red docker-proof-local docker-proof-50k docker-proof-100k docker-proof-post-100k-to-tip docker-shadow-5k-proof docker-shadow-50k-proof docker-shadow-100k-proof docker-shadow-post-100k-to-tip docker-pure-5k-proof docker-pure-100k-proof docker-pure-post-100k-to-tip docker-smoke-once docker-toolchain-smoke docker-parallel-runner-smoke docker-native-boundary-audit
.PHONY: mojo-docs-cache mojo-docs-status clean

host-deps-check:
	@command -v brew >/dev/null || { echo "missing Homebrew; install brew first" >&2; exit 1; }
	@command -v $(UV) >/dev/null || { echo "missing uv; run 'brew install uv'" >&2; exit 1; }
	@test -x "$(PYTHON)" || { echo "missing $(PYTHON); run 'brew install python@3.11'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists rocksdb || { echo "missing rocksdb pkg-config metadata; run 'brew install rocksdb'" >&2; exit 1; }
	@$(PKG_CONFIG) --exists libsecp256k1 || { echo "missing libsecp256k1 pkg-config metadata; run 'brew install secp256k1'" >&2; exit 1; }

host-deps-install:
	brew install uv rocksdb secp256k1 pkgconf python@3.11

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
	  $$($(PKG_CONFIG) --cflags --libs rocksdb libsecp256k1) \
	  -lstdc++

$(MOJO_BIN): src/mojobitnode.mojo src/block_core.mojo src/script_corpus_foundation.mojo src/script_corpus_table.mojo src/pure_secp.mojo $(MOJO_VERSION_STAMP) $(SHIM_LIB)
	$(MOJO) build -I src src/mojobitnode.mojo -o $(MOJO_BIN)

host-build: host-deps-check $(MOJO_BIN)

host-native-boundary-audit: host-build
	$(PYTHON) $(MOJO_NATIVE_BOUNDARY_AUDIT) --shim $(SHIM_LIB)

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

host-pure-crypto-profile: host-build
	@mkdir -p .benchmark-results
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) pure-crypto-profile \
	  --result-path $(HOST_PURE_CRYPTO_PROFILE_RESULT)); \
	  echo "$$out"; \
	  grep -q '"schema":"port.pure_crypto_profile.v1"' <<< "$$out"; \
	  grep -q '"glv_matches_native":true' <<< "$$out"; \
	  grep -q '"result":"diagnostic"' <<< "$$out"; \
	  test -s "$(HOST_PURE_CRYPTO_PROFILE_RESULT)"

host-pure-crypto-microbench: host-build
	@mkdir -p .benchmark-results
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) pure-crypto-microbench \
	  --iterations $(PURE_CRYPTO_MICROBENCH_ITERS) \
	  --case $(PURE_CRYPTO_MICROBENCH_CASE) \
	  --result-path $(HOST_PURE_CRYPTO_MICROBENCH_RESULT)); \
	  echo "$$out"; \
	  grep -q '"schema":"port.pure_crypto_microbench.v1"' <<< "$$out"; \
	  grep -q '"native_compare_enabled":false' <<< "$$out"; \
	  grep -q '"glv_wnaf_mismatches":0' <<< "$$out"; \
	  grep -q '"fe52_mismatches":0' <<< "$$out"; \
	  grep -q '"mismatches":0' <<< "$$out"; \
	  grep -q '"result":"diagnostic"' <<< "$$out"; \
	  test -s "$(HOST_PURE_CRYPTO_MICROBENCH_RESULT)"

host-storage-proof: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) storage-proof \
	  --datadir $(PROOF_DATA_DIR) \
	  --result-path $(HOST_STORAGE_RESULT)); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

host-script-corpus-dev: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus-dev \
	  --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json \
	  $(if $(FIXTURE_ID),--fixture-id $(FIXTURE_ID),--fixture-set $(FIXTURE_SET)) \
	  --result-path $(HOST_SCRIPT_CORPUS_DEV_RESULT)); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"delegated":false' <<< "$$out"; \
	  test -s "$(HOST_SCRIPT_CORPUS_DEV_RESULT)"

host-script-corpus: host-build
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus \
	  --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(SCRIPT_CORPUS_RESULT); \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"; \
	  grep -q '"delegated":false' <<< "$$out"; \
	  grep -q '"fixture_count":45' <<< "$$out"; \
	  grep -q '"passed":45' <<< "$$out"; \
	  grep -q '"failed":0' <<< "$$out"; \
	  test -s "$(SCRIPT_CORPUS_RESULT)"

host-script-corpus-shadow: host-build
	@mkdir -p .benchmark-results
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus \
	  --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json \
	  --shadow-crypto \
	  --result-path $(HOST_SCRIPT_CORPUS_SHADOW_RESULT)); \
	  echo "$$out"; \
	  grep -q '"schema":"port.script_corpus_shadow_crypto.v1"' <<< "$$out"; \
	  grep -q '"shadow_crypto_backend":"mojo-pure-secp256k1"' <<< "$$out"; \
	  grep -q '"shadow_used_native_fallback":false' <<< "$$out"; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_shadow_crypto.py --require-shadow-timing --max-shadow-row-ms 5000 --require-shadow-large-fixture-metrics $(HOST_SCRIPT_CORPUS_SHADOW_RESULT)

host-script-corpus-reject: host-build
	@mkdir -p .benchmark-results
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus-reject \
	  --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json \
	  --crypto-backend native \
	  --result-path $(HOST_SCRIPT_CORPUS_REJECT_NATIVE_RESULT)); \
	  echo "$$out"; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py $(HOST_SCRIPT_CORPUS_REJECT_NATIVE_RESULT)
	@out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) script-corpus-reject \
	  --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json \
	  --crypto-backend pure \
	  --result-path $(HOST_SCRIPT_CORPUS_REJECT_PURE_RESULT)); \
	  echo "$$out"; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py $(HOST_SCRIPT_CORPUS_REJECT_PURE_RESULT)

host-script-corpus-reject-red: host-build
	@mkdir -p .benchmark-results
	@for fault in accept_ecdsa accept_schnorr accept_taptweak; do \
	  result=.benchmark-results/mojo_host_script_corpus_reject_red_$${fault}_$(RESULT_DATE).json; \
	  out=$$(MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) \
	    MOJOBITNODE_ENABLE_REJECT_FAULTS=1 MOJOBITNODE_PURE_CRYPTO_FAULT=$$fault \
	    $(MOJO_BIN) script-corpus-reject \
	      --manifest $(RB_FIXTURE_SHARED)/conformance/fixtures/scripts/manifest.json \
	      --crypto-backend pure \
	      --result-path $$result); \
	  echo "$$out"; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py --expect-red $$result; \
	done

host-local-reference-proof: host-build
	@mkdir -p .benchmark-results
	@MOJOBITNODE_RUNTIME_SURFACE=host \
	  MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) \
	  MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) \
	  MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) \
	  MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) \
	  MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH) \
	  $(MOJO_BIN) local-reference-proof \
	  --datadir $(PROOF_DATA_DIR) \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(HOST_P2P_PEER) \
	  --progress $(PROGRESS) \
	  $(PROOF_EXTRA_ARGS) \
	  --result-path $(HOST_LOCAL_PROOF_RESULT)

host-shakedown-50k-proof:
	$(MAKE) host-local-reference-proof DOCKER_SYNC_TARGET=50000 HOST_LOCAL_PROOF_RESULT=$(HOST_50K_PROOF_RESULT) PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)

host-shadow-5k-proof:
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then rm -rf $(HOST_SHADOW_5K_DATA_DIR); fi
	$(MAKE) host-local-reference-proof DOCKER_SYNC_TARGET=5000 PROOF_DATA_DIR=$(HOST_SHADOW_5K_DATA_DIR) HOST_LOCAL_PROOF_RESULT=$(HOST_SHADOW_5K_PROOF_RESULT) PROOF_EXTRA_ARGS=--shadow-crypto PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate baseline_5k --require-zero-unsupported --artifact $(HOST_SHADOW_5K_PROOF_RESULT)

host-shadow-50k-proof:
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then rm -rf $(HOST_SHADOW_50K_DATA_DIR); fi
	$(MAKE) host-local-reference-proof DOCKER_SYNC_TARGET=50000 PROOF_DATA_DIR=$(HOST_SHADOW_50K_DATA_DIR) HOST_LOCAL_PROOF_RESULT=$(HOST_SHADOW_50K_PROOF_RESULT) PROOF_EXTRA_ARGS=--shadow-crypto PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate shakedown_50k --require-zero-unsupported --artifact $(HOST_SHADOW_50K_PROOF_RESULT)

host-pure-5k-proof:
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then rm -rf $(HOST_PURE_5K_DATA_DIR); fi
	$(MAKE) host-local-reference-proof DOCKER_SYNC_TARGET=5000 PROOF_DATA_DIR=$(HOST_PURE_5K_DATA_DIR) HOST_LOCAL_PROOF_RESULT=$(HOST_PURE_5K_PROOF_RESULT) PROOF_EXTRA_ARGS="--crypto-backend pure" PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_pure_crypto_proof.py --gate baseline_5k --artifact $(HOST_PURE_5K_PROOF_RESULT)

host-smoke-once: host-build
	@MOJOBITNODE_RUNTIME_SURFACE=host MOJOBITNODE_SHIM_PATH=$(abspath $(SHIM_LIB)) $(MOJO_BIN) status --datadir $(DATA_DIR) --json >/tmp/mojo_status.json; \
	  grep -q '"entrypoint_language":"mojo"' /tmp/mojo_status.json; \
	  printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/mojo_status.json)"

host-toolchain-smoke: $(MOJO_VERSION_STAMP)
	$(MOJO) run $(MOJO_TOOLCHAIN_SMOKE)

host-parallel-runner-smoke: $(MOJO_VERSION_STAMP)
	$(MOJO) run $(MOJO_PARALLEL_RUNNER_SMOKE)

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

docker-native-boundary-audit:
	$(DOCKER_COMPOSE) run --rm --no-deps --entrypoint python3 mojobitnode \
	  /usr/local/share/mojobitnode/scripts/native_boundary_audit.py \
	  --shim /usr/local/lib/libmojobitnode_shim.so \
	  --package-list-command "dpkg-query -W"

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

docker-pure-crypto-profile:
	@mkdir -p .benchmark-results
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode pure-crypto-profile \
	  --result-path /tmp/mojo_pure_crypto_profile.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(DOCKER_PURE_CRYPTO_PROFILE_RESULT); \
	  grep -q '"schema":"port.pure_crypto_profile.v1"' <<< "$$out"; \
	  grep -q '"runtime_surface":"docker"' <<< "$$out"; \
	  grep -q '"glv_matches_native":true' <<< "$$out"; \
	  grep -q '"result":"diagnostic"' <<< "$$out"

docker-pure-crypto-microbench:
	@mkdir -p .benchmark-results
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode pure-crypto-microbench \
	  --iterations $(PURE_CRYPTO_MICROBENCH_ITERS) \
	  --case $(PURE_CRYPTO_MICROBENCH_CASE) \
	  --result-path /tmp/mojo_pure_crypto_microbench.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(DOCKER_PURE_CRYPTO_MICROBENCH_RESULT); \
	  grep -q '"schema":"port.pure_crypto_microbench.v1"' <<< "$$out"; \
	  grep -q '"runtime_surface":"docker"' <<< "$$out"; \
	  grep -q '"native_compare_enabled":false' <<< "$$out"; \
	  grep -q '"glv_wnaf_mismatches":0' <<< "$$out"; \
	  grep -q '"fe52_mismatches":0' <<< "$$out"; \
	  grep -q '"mismatches":0' <<< "$$out"; \
	  grep -q '"result":"diagnostic"' <<< "$$out"

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

docker-script-corpus-shadow:
	@mkdir -p .benchmark-results
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode script-corpus \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	  --shadow-crypto \
	  --result-path /tmp/mojo_script_corpus_shadow.json); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(DOCKER_SCRIPT_CORPUS_SHADOW_RESULT); \
	  grep -q '"schema":"port.script_corpus_shadow_crypto.v1"' <<< "$$out"; \
	  grep -q '"runtime_surface":"docker"' <<< "$$out"; \
	  grep -q '"shadow_used_native_fallback":false' <<< "$$out"; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_shadow_crypto.py --require-shadow-timing --max-shadow-row-ms 5000 --require-shadow-large-fixture-metrics $(DOCKER_SCRIPT_CORPUS_SHADOW_RESULT)

docker-script-corpus-reject:
	@mkdir -p .benchmark-results
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode script-corpus-reject \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	  --crypto-backend native); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(DOCKER_SCRIPT_CORPUS_REJECT_NATIVE_RESULT); \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py $(DOCKER_SCRIPT_CORPUS_REJECT_NATIVE_RESULT)
	@out=$$($(DOCKER_COMPOSE) run --rm --no-deps mojobitnode script-corpus-reject \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	  --crypto-backend pure); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $(DOCKER_SCRIPT_CORPUS_REJECT_PURE_RESULT); \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py $(DOCKER_SCRIPT_CORPUS_REJECT_PURE_RESULT)

docker-script-corpus-reject-red:
	@mkdir -p .benchmark-results
	@for fault in accept_ecdsa accept_schnorr accept_taptweak; do \
	  result=.benchmark-results/mojo_docker_script_corpus_reject_red_$${fault}_$(RESULT_DATE).json; \
	  out=$$($(DOCKER_COMPOSE) run --rm --no-deps \
	    -e MOJOBITNODE_ENABLE_REJECT_FAULTS=1 \
	    -e MOJOBITNODE_PURE_CRYPTO_FAULT=$$fault \
	    mojobitnode script-corpus-reject \
	      --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	      --crypto-backend pure); \
	  echo "$$out"; \
	  printf "%s\n" "$$out" > $$result; \
	  python3 ../Shared/conformance/tools/validate_script_corpus_reject_result.py --expect-red $$result; \
	done

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@mkdir -p .benchmark-results
	@if [ "$(PRESERVE_PROOF_VOLUME)" != "1" ]; then docker volume rm -f $(PROOF_VOLUME) docker_$(PROOF_VOLUME) >/dev/null 2>&1 || true; fi
	DOCKER_DATA_VOLUME=$(PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e REFERENCE_P2P_PEER=$(DOCKER_P2P_PEER) \
	  -e MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) \
	  -e MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) \
	  -e MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) \
	  -e MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH) \
	  mojobitnode local-reference-proof \
	  --datadir /data \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --progress $(PROGRESS) \
	  $(PROOF_EXTRA_ARGS) \
	  --result-path /benchmark-results/$(notdir $(DOCKER_LOCAL_PROOF_RESULT))

docker-proof-50k:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PROOF_50K_VOLUME) DOCKER_SYNC_TARGET=50000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT) PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)

docker-proof-100k:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PROOF_100K_VOLUME) DOCKER_SYNC_TARGET=100000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_100K_PROOF_RESULT) PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)

docker-status-100k:
	@out=$$(DOCKER_DATA_VOLUME=$(PROOF_100K_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps mojobitnode status --datadir /data --json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-status-shadow-100k:
	@out=$$(DOCKER_DATA_VOLUME=$(SHADOW_100K_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps mojobitnode status --datadir /data --json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-status-pure-100k:
	@out=$$(DOCKER_DATA_VOLUME=$(PURE_100K_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps mojobitnode status --datadir /data --json); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-proof-post-100k-to-tip:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PROOF_100K_VOLUME) DOCKER_SYNC_TARGET=$(POST_100K_TIP_TARGET) DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_POST_100K_TO_TIP_RESULT) PROOF_EXTRA_ARGS=--resume-from-state PRESERVE_PROOF_VOLUME=1 PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)

docker-shadow-5k-proof:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(SHADOW_5K_PROOF_VOLUME) DOCKER_SYNC_TARGET=5000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_SHADOW_5K_PROOF_RESULT) PROOF_EXTRA_ARGS=--shadow-crypto PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate baseline_5k --require-zero-unsupported --artifact $(DOCKER_SHADOW_5K_PROOF_RESULT)

docker-shadow-50k-proof:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(SHADOW_50K_PROOF_VOLUME) DOCKER_SYNC_TARGET=50000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_SHADOW_50K_PROOF_RESULT) PROOF_EXTRA_ARGS=--shadow-crypto PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate shakedown_50k --require-zero-unsupported --artifact $(DOCKER_SHADOW_50K_PROOF_RESULT)

docker-shadow-100k-proof:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(SHADOW_100K_PROOF_VOLUME) DOCKER_SYNC_TARGET=100000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_SHADOW_100K_PROOF_RESULT) PROOF_EXTRA_ARGS=--shadow-crypto PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate performance_100k --require-zero-unsupported --artifact $(DOCKER_SHADOW_100K_PROOF_RESULT)

docker-shadow-post-100k-to-tip:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(SHADOW_100K_PROOF_VOLUME) DOCKER_SYNC_TARGET=$(POST_100K_TIP_TARGET) DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_SHADOW_POST_100K_TO_TIP_RESULT) PROOF_EXTRA_ARGS="--shadow-crypto --resume-from-state" PRESERVE_PROOF_VOLUME=1 PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_shadow_crypto_proof.py --gate post_100k_to_tip --require-zero-unsupported --artifact $(DOCKER_SHADOW_POST_100K_TO_TIP_RESULT)

docker-pure-5k-proof:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PURE_5K_PROOF_VOLUME) DOCKER_SYNC_TARGET=5000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_PURE_5K_PROOF_RESULT) PROOF_EXTRA_ARGS="--crypto-backend pure" PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=$(MOJOBITNODE_PAR_SCRIPT_VERIFY) MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_pure_crypto_proof.py --gate baseline_5k --artifact $(DOCKER_PURE_5K_PROOF_RESULT)

docker-pure-100k-proof:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PURE_100K_PROOF_VOLUME) DOCKER_SYNC_TARGET=100000 DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_PURE_100K_PROOF_RESULT) PROOF_EXTRA_ARGS="--crypto-backend pure" PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_pure_crypto_proof.py --gate performance_100k --artifact $(DOCKER_PURE_100K_PROOF_RESULT)

docker-pure-post-100k-to-tip:
	$(MAKE) docker-proof-local PROOF_VOLUME=$(PURE_100K_PROOF_VOLUME) DOCKER_SYNC_TARGET=$(POST_100K_TIP_TARGET) DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_PURE_POST_100K_TO_TIP_RESULT) PROOF_EXTRA_ARGS="--crypto-backend pure --resume-from-state" PRESERVE_PROOF_VOLUME=1 PROGRESS=$(PROGRESS) MOJOBITNODE_PAR_SCRIPT_VERIFY=1 MOJOBITNODE_SCRIPT_THREADS=$(MOJOBITNODE_SCRIPT_THREADS) MOJOBITNODE_SCRIPT_MIN_INPUTS=$(MOJOBITNODE_SCRIPT_MIN_INPUTS) MOJOBITNODE_PROFILE_HOTPATH=$(MOJOBITNODE_PROFILE_HOTPATH)
	python3 ../Shared/conformance/tools/validate_pure_crypto_proof.py --gate post_100k_to_tip --artifact $(DOCKER_PURE_POST_100K_TO_TIP_RESULT)

docker-smoke-once:
	@out=$$(DOCKER_DATA_VOLUME=$(DATA_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /bin/sh mojobitnode -lc 'mojobitnode status --datadir /data --json >/tmp/status.json && printf "%s %s\n" "AGENT_LOOP_TICK_chatreport" "$$(cat /tmp/status.json)"'); \
	  echo "$$out"; \
	  grep -q '"entrypoint_language":"mojo"' <<< "$$out"

docker-toolchain-smoke:
	$(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /opt/mojo/bin/mojo mojobitnode run /usr/local/share/mojobitnode/tests/toolchain_smoke.mojo

docker-parallel-runner-smoke:
	$(DOCKER_COMPOSE) run --rm --no-deps --entrypoint /opt/mojo/bin/mojo mojobitnode run /usr/local/share/mojobitnode/tests/parallel_runner_smoke.mojo

clean:
	rm -rf data-mojo data-mojo-proof build .venv .benchmark-results .mojo-docs

include ../Shared/fixture_package.mk
host-build host-script-corpus-dev host-script-corpus host-script-corpus-shadow host-script-corpus-reject host-script-corpus-reject-red host-script-corpus-foundation-smoke docker-build docker-script-corpus docker-script-corpus-shadow docker-script-corpus-reject docker-script-corpus-reject-red: | fixture-package
