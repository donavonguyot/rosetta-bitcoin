CARGO ?= cargo
DATA_DIR ?= ./data-rust
PROOF_DATA_DIR ?= ./data-rust-proof
RESULT_DATE ?= $(shell date +%F)
STORAGE_RESULT ?= ../../NodeCore/conformance/results/rust_storage_gate_$(RESULT_DATE).json
SCRIPT_RESULT ?= ../../NodeCore/conformance/results/rust_script_corpus_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml

.PHONY: build test rust-node-status rust-node-storage-proof rust-node-codec-vectors rust-node-native-crypto-vectors rust-node-script-corpus docker-config docker-build docker-status docker-proof-local docker-smoke-once clean

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

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build rsbitnode

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode rsbitnode status --datadir /data --runtime-surface docker

docker-proof-local:
	@docker volume rm -f rsbitnode_proof_data >/dev/null 2>&1 || true
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-proof rsbitnode storage-proof --datadir /data --result-path /results/rust_storage_gate_docker_$(RESULT_DATE).json --runtime-surface docker

docker-smoke-once:
	$(DOCKER_COMPOSE) run --rm --no-deps rsbitnode-supervisor

clean:
	rm -rf data-rust data-rust-proof target
