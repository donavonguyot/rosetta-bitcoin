SHELL := /bin/bash

DATA_DIR ?= ./data-ocaml
RESULTS_DIR ?= ../Shared/conformance/results
SCRIPT_MANIFEST ?= ../Shared/conformance/fixtures/scripts/manifest.json
CRYPTO_VECTORS ?= ../Shared/conformance/fixtures/native_crypto_v1_vectors.json
RESULT_DATE ?= $(shell date -u +%F)
FIXTURE_ID ?=
FIXTURE_ARG := $(if $(FIXTURE_ID),--fixture-id $(FIXTURE_ID),)
DOCKER_COMPOSE := docker compose -f docker/docker-compose.yml

.PHONY: build test ocbitnode-status ocbitnode-storage-proof ocbitnode-native-crypto-vectors ocbitnode-script-corpus
.PHONY: docker-config docker-build docker-warm docker-status docker-storage-proof docker-native-crypto-vectors docker-script-corpus docker-smoke-once

build:
	opam exec -- dune build @install

test:
	opam exec -- dune runtest

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

docker-smoke-once: docker-status docker-native-crypto-vectors docker-storage-proof docker-script-corpus
