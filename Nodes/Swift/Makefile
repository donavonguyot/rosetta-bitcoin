SWIFT ?= swift
DATA_DIR ?= ./data-swift
RESULT_DATE ?= $(shell date +%F)
SCRIPT_RESULT ?= ../Shared/conformance/results/swift_script_corpus_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /results/swift_script_corpus_$(RESULT_DATE).json
DOCKER_LOCAL_PROOF_RESULT ?= /results/swift_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_PROOF_RESULT ?= /results/swift_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_PROOF_RESULT ?= /results/swift_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_P2P_PEER ?= host.docker.internal:48333
DOCKER_PROOF_VOLUME ?= swiftbitnode_proof_data
DOCKER_SYNC_TARGET ?= 5000
DOCKER_SUPERVISOR_TARGET ?= 10000
DOCKER_SUPERVISOR_CHUNK ?= 5000
DOCKER_SUPERVISOR_RESULT ?= /results/swift_supervisor_status_$(RESULT_DATE).json

.PHONY: build test swift-node-status swift-node-native-crypto-vectors swift-node-script-corpus swift-node-proof-local swift-node-sync-supervisor docker-config docker-build docker-warm docker-status docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-supervisor docker-supervisor-status docker-supervisor-stop docker-supervisor-resume clean

build:
	$(SWIFT) build

test:
	$(SWIFT) test

swift-node-status:
	$(SWIFT) run swiftbitnode status --datadir $(DATA_DIR)

swift-node-native-crypto-vectors:
	$(SWIFT) run swiftbitnode native-crypto-vectors

swift-node-script-corpus:
	$(SWIFT) run swiftbitnode script-corpus \
	  --manifest ../Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(SCRIPT_RESULT)

swift-node-proof-local:
	$(SWIFT) run swiftbitnode proof-local \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --output ../Shared/conformance/results/swift_docker_baseline_5k_benchmark_$(RESULT_DATE).json

swift-node-sync-supervisor:
	$(SWIFT) run swiftbitnode sync-supervisor \
	  --target $(DOCKER_SUPERVISOR_TARGET) \
	  --chunk-size $(DOCKER_SUPERVISOR_CHUNK) \
	  --peer $(DOCKER_P2P_PEER) \
	  --datadir $(DATA_DIR)

docker-config:
	$(DOCKER_COMPOSE) config >/dev/null

docker-build:
	$(DOCKER_COMPOSE) build

docker-warm: docker-build

docker-status:
	$(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode swiftbitnode status --datadir /data

docker-script-corpus:
	$(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode-script-corpus \
	  swiftbitnode script-corpus \
	  --manifest /workspace/Shared/conformance/fixtures/scripts/manifest.json \
	  --output $(DOCKER_SCRIPT_RESULT)

docker-proof-local:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e HEADER_TARGET_HEIGHT=$(DOCKER_SYNC_TARGET) \
	  -e PREFETCH_DEPTH=4 \
	  -e SCRIPT_RUNNER_MODE=parallel \
	  -e ROCKSDB_WAL_DISABLED=false \
	  -e FRESH_STATE=true \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  swiftbitnode-local-reference-proof \
	  swiftbitnode proof-local \
	  --target $(DOCKER_SYNC_TARGET) \
	  --peer $(DOCKER_P2P_PEER) \
	  --output $(DOCKER_LOCAL_PROOF_RESULT)

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=swiftbitnode_10k_proof_data \
	  DOCKER_SYNC_TARGET=10000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_10K_PROOF_RESULT)

docker-proof-50k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=swiftbitnode_50k_proof_data \
	  DOCKER_SYNC_TARGET=50000 \
	  DOCKER_LOCAL_PROOF_RESULT=$(DOCKER_50K_PROOF_RESULT)

docker-supervisor:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps \
	  -e TARGET_HEIGHT=$(DOCKER_SUPERVISOR_TARGET) \
	  -e CHUNK_SIZE=$(DOCKER_SUPERVISOR_CHUNK) \
	  -e PREFETCH_DEPTH=4 \
	  -e PEER=$(DOCKER_P2P_PEER) \
	  swiftbitnode \
	  swiftbitnode sync-supervisor \
	  --target $(DOCKER_SUPERVISOR_TARGET) \
	  --chunk-size $(DOCKER_SUPERVISOR_CHUNK) \
	  --peer $(DOCKER_P2P_PEER) \
	  --datadir /data \
	  --output $(DOCKER_SUPERVISOR_RESULT)

docker-supervisor-status:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode swiftbitnode status --datadir /data

docker-supervisor-stop:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode /bin/sh -lc 'touch /data/.swiftbitnode_supervisor_stop'

docker-supervisor-resume:
	DOCKER_DATA_VOLUME=swiftbitnode_supervisor_data $(DOCKER_COMPOSE) run --rm --no-deps swiftbitnode /bin/sh -lc 'rm -f /data/.swiftbitnode_supervisor_stop'

clean:
	rm -rf .build data-swift
