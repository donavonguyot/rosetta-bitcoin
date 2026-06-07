SHELL := /bin/bash

DATA_DIR ?= ./data-ocaml
RESULTS_DIR ?= ../Shared/conformance/results
SCRIPT_MANIFEST ?= ../Shared/conformance/fixtures/scripts/manifest.json
CRYPTO_VECTORS ?= ../Shared/conformance/fixtures/native_crypto_v1_vectors.json
RESULT_DATE ?= $(shell date -u +%F)
FIXTURE_ID ?=
FIXTURE_ARG := $(if $(FIXTURE_ID),--fixture-id $(FIXTURE_ID),)
SYNC_TARGET ?= 5000
DOCKER_50K_PROFILE_TARGET ?= $(if $(filter 5000,$(SYNC_TARGET)),26700,$(SYNC_TARGET))
PREFETCH_DEPTH ?= 4
PROGRESS ?= 1000
DOCKER_LOCAL_PROOF_VOLUME ?= ocbitnode_5k_proof_data
DOCKER_LOCAL_REFERENCE_RESULT ?= /tmp/ocaml_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_LOCAL_TELEMETRY_LOG ?= /tmp/ocaml_docker_baseline_5k_telemetry_$(RESULT_DATE).log
DOCKER_50K_PROOF_VOLUME ?= ocbitnode_50k_proof_data
DOCKER_50K_REFERENCE_RESULT ?= /tmp/ocaml_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_50K_TELEMETRY_LOG ?= /tmp/ocaml_docker_shakedown_50k_telemetry_$(RESULT_DATE).log
DOCKER_100K_PROOF_VOLUME ?= ocbitnode_100k_proof_data
DOCKER_100K_REFERENCE_RESULT ?= /tmp/ocaml_docker_performance_100k_benchmark_$(RESULT_DATE).json
DOCKER_100K_TELEMETRY_LOG ?= /tmp/ocaml_docker_performance_100k_telemetry_$(RESULT_DATE).log
DOCKER_50K_PROFILE_VOLUME ?= ocbitnode_50k_profile_data
DOCKER_50K_PROFILE_RESULT ?= /workspace/Shared/conformance/results/ocaml_docker_shakedown_50k_profile_$(DOCKER_50K_PROFILE_TARGET)_$(RESULT_DATE).json
DOCKER_50K_PROFILE_TELEMETRY_LOG ?= /workspace/Shared/conformance/results/ocaml_docker_shakedown_50k_profile_$(DOCKER_50K_PROFILE_TARGET)_$(RESULT_DATE).log
DOCKER_COMPOSE := docker compose --env-file ../Shared/docker/reference_topology.env -f docker/docker-compose.yml
include ../Shared/docker/reference_topology.mk
VALIDATE_BENCHMARK_ARTIFACT ?= python3 ../Shared/conformance/tools/validate_benchmark_artifact.py

.PHONY: build test docker-test ocbitnode-status ocbitnode-storage-proof ocbitnode-native-crypto-vectors ocbitnode-script-corpus
.PHONY: docker-config docker-build docker-warm docker-status docker-storage-proof docker-native-crypto-vectors docker-script-corpus docker-proof-local docker-proof-50k docker-proof-100k docker-proof-50k-profile docker-smoke-once

build:
	opam exec -- dune build @install

test:
	@if command -v opam >/dev/null 2>&1; then \
	  opam exec -- dune runtest; \
	else \
	  $(MAKE) docker-test; \
	fi

docker-test:
	$(DOCKER_COMPOSE) run --rm --entrypoint /bin/bash ocbitnode -lc 'opam exec -- dune runtest'

ocbitnode-status:
	opam exec -- dune exec -- ocbitnode status --datadir $(DATA_DIR)

ocbitnode-storage-proof:
	opam exec -- dune exec -- ocbitnode storage-proof --datadir $(DATA_DIR) --result-path $(RESULTS_DIR)/ocaml_rocksdb_codec_v2_storage_$(RESULT_DATE).json

ocbitnode-native-crypto-vectors:
	opam exec -- dune exec -- ocbitnode native-crypto-vectors --vectors $(CRYPTO_VECTORS) --result-path $(RESULTS_DIR)/ocaml_native_crypto_vectors_$(RESULT_DATE).json

ocbitnode-script-corpus:
	opam exec -- dune exec -- ocbitnode script-corpus --manifest $(SCRIPT_MANIFEST) --result-path $(RESULTS_DIR)/ocaml_script_corpus_$(RESULT_DATE).json --runtime-surface host $(FIXTURE_ARG)

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build ocbitnode

docker-warm: docker-build

docker-status:
	$(DOCKER_COMPOSE) run --rm ocbitnode status --datadir /data

docker-storage-proof:
	$(DOCKER_COMPOSE) run --rm ocbitnode storage-proof --datadir /data --result-path /workspace/Shared/conformance/results/ocaml_rocksdb_codec_v2_storage_docker_$(RESULT_DATE).json

docker-native-crypto-vectors:
	$(DOCKER_COMPOSE) run --rm ocbitnode native-crypto-vectors --vectors /workspace/Shared/conformance/fixtures/native_crypto_v1_vectors.json --result-path /workspace/Shared/conformance/results/ocaml_native_crypto_vectors_docker_$(RESULT_DATE).json

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm ocbitnode script-corpus --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json --result-path /workspace/Shared/conformance/results/ocaml_script_corpus_docker_$(RESULT_DATE).json --runtime-surface docker $(FIXTURE_ARG)

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@$(DOCKER_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true
	@docker volume rm $(DOCKER_LOCAL_PROOF_VOLUME) docker_$(DOCKER_LOCAL_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_LOCAL_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm ocbitnode local-reference-proof --datadir /data --target $(SYNC_TARGET) --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_LOCAL_REFERENCE_RESULT) --runtime-surface docker --telemetry-log $(DOCKER_LOCAL_TELEMETRY_LOG)

docker-proof-50k:
	$(REFERENCE_P2P_CHECK)
	@$(DOCKER_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true
	@docker volume rm $(DOCKER_50K_PROOF_VOLUME) docker_$(DOCKER_50K_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_50K_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm ocbitnode local-reference-proof --datadir /data --target 50000 --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_50K_REFERENCE_RESULT) --runtime-surface docker --telemetry-log $(DOCKER_50K_TELEMETRY_LOG)

docker-proof-100k:
	$(REFERENCE_P2P_CHECK)
	@$(DOCKER_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true
	@docker volume rm $(DOCKER_100K_PROOF_VOLUME) docker_$(DOCKER_100K_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_100K_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm ocbitnode local-reference-proof --datadir /data --target 100000 --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_100K_REFERENCE_RESULT) --runtime-surface docker --telemetry-log $(DOCKER_100K_TELEMETRY_LOG)

docker-proof-50k-profile:
	$(REFERENCE_P2P_CHECK)
	@$(DOCKER_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true
	@docker volume rm $(DOCKER_50K_PROFILE_VOLUME) docker_$(DOCKER_50K_PROFILE_VOLUME) >/dev/null 2>&1 || true
	DOCKER_LOCAL_PROOF_VOLUME=$(DOCKER_50K_PROFILE_VOLUME) $(DOCKER_COMPOSE) run --rm ocbitnode local-reference-proof --datadir /data --target $(DOCKER_50K_PROFILE_TARGET) --peer $(DOCKER_P2P_PEER) --progress $(PROGRESS) --result-path $(DOCKER_50K_PROFILE_RESULT) --runtime-surface docker --telemetry-log $(DOCKER_50K_PROFILE_TELEMETRY_LOG)

docker-smoke-once: docker-status docker-native-crypto-vectors docker-storage-proof docker-script-corpus
