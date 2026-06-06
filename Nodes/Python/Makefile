PYTHON ?= .venv/bin/python
PYBITNODE_SYNC ?= .venv/bin/pybitnode-sync
PYBITNODE_DB ?= .venv/bin/pybitnode-db
PYBITNODE_ROCKSDB_PROOF ?= .venv/bin/pybitnode-rocksdb-proof
DATA_DIR ?= ./data
STATE_PATH ?= $(DATA_DIR)/chainstate-rocksdb
PEERS ?= 127.0.0.1:48333
BLOCKS_MAX ?= 5000
OVERNIGHT_BLOCKS_MAX ?= 15000
TARGET ?=
LOG ?= sync_chunk.log
SCAN_BLOCKS ?= 20
OUT ?= snapshots
DOCKER_PROOF_VOLUME ?= pybitnode_proof_data
DOCKER_SUPERVISOR_VOLUME ?= pybitnode_supervisor_data
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/python_rocksdb_native_storage_2026-06-02.json
RESULT_DATE ?= $(shell date +%F)
SUPPORTING_5K_RESULT ?= /results/python_docker_supporting_5k_benchmark_$(RESULT_DATE).json
SUPPORTING_10K_RESULT ?= /results/python_docker_supporting_10k_benchmark_$(RESULT_DATE).json
DOCKER_BENCHMARK_TARGET ?= 5000
SCRIPT_RESULT ?= ../Shared/conformance/results/python_script_corpus_$(RESULT_DATE).json
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/python_script_corpus_docker_$(RESULT_DATE).json
REFERENCE_DOCKER_NETWORK ?= rosetta-reference-node_default
DOCKER_P2P_PEER ?= bitcoin-core-testnet4:48333
DOCKER_PREFETCH_DEPTH ?= 4
DOCKER_SCRIPT_THREADS ?= 4
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_REBUILD ?= 0
REFERENCE_P2P_CHECK = docker run --rm --network $(REFERENCE_DOCKER_NETWORK) -v $(abspath ../Shared/docker):/shared/docker:ro python:3.12-alpine python3 /shared/docker/check_reference_p2p.py --peer $(DOCKER_P2P_PEER)

SYNC_ENV = MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1

.PHONY: python-node-status python-node-preflight python-node-rocksdb-proof python-node-script-corpus docker-build docker-warm docker-script-corpus docker-proof-local docker-proof-10k docker-python-rocksdb-proof docker-python-supervisor docker-python-supervisor-status docker-python-supervisor-stop docker-python-supervisor-resume python-node-sync-local-reference python-node-sync-chunk python-node-sync-chunk-overnight python-node-sync-supervisor python-node-export-snapshots python-node-survey-scripts test

test:
	$(PYTHON) -m pytest -q

python-node-status:
	$(PYBITNODE_DB) --state-path $(STATE_PATH)

python-node-rocksdb-proof:
	$(PYBITNODE_ROCKSDB_PROOF) --datadir $(DATA_DIR)-proof --proof-path $(DOCKER_PROOF_PATH)

python-node-script-corpus:
	PYBITNODE_RUNTIME_SURFACE=host $(PYTHON) -m pybitnode.conformance.script_corpus --result-path $(SCRIPT_RESULT)

# Fail if a pybitnode-sync writer appears active; otherwise print DB status.
python-node-preflight:
	@ps -ax -o pid= -o command= | $(PYTHON) -c 'import sys; rows=[line for line in sys.stdin if "pybitnode-sync" in line and " -c " not in line]; [print(line, end="") for line in rows]; raise SystemExit(1 if rows else 0)'
	$(MAKE) python-node-status DATA_DIR=$(DATA_DIR) STATE_PATH=$(STATE_PATH)

python-node-sync-local-reference:
	$(SYNC_ENV) $(PYBITNODE_SYNC) --datadir $(DATA_DIR) --peers $(PEERS)

# Normal Cursor catch-up chunk: local Reference peer, lightweight block sync, bounded run.
python-node-sync-chunk:
	@target_arg=""; if [ -n "$(TARGET)" ]; then target_arg="--blocks-target $(TARGET)"; fi; \
	$(SYNC_ENV) $(PYBITNODE_SYNC) --datadir $(DATA_DIR) $$target_arg --blocks-max $(BLOCKS_MAX) \
	  --no-header-refresh --peers $(PEERS)

# Long unattended chunk. Same single-writer rules; override OVERNIGHT_BLOCKS_MAX or BLOCKS_MAX deliberately.
python-node-sync-chunk-overnight:
	$(MAKE) python-node-sync-chunk DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) TARGET="$(TARGET)" BLOCKS_MAX=$(OVERNIGHT_BLOCKS_MAX)

# Durable supervisor: Java-style subchunks, stop file, restart-on-crash, and 2-minute chat ticks.
python-node-sync-supervisor:
	CHUNK_TOTAL=$${CHUNK_TOTAL:-15000} SUBCHUNK_SIZE=$${SUBCHUNK_SIZE:-500} \
	  DATA_DIR=$(DATA_DIR) STATE_PATH=$(STATE_PATH) PEERS=$(PEERS) ./scripts/sync_supervisor.sh

python-node-export-snapshots:
	$(PYTHON) scripts/export_snapshots.py --state-path $(STATE_PATH) --out $(OUT)

python-node-survey-scripts:
	PYTHONPATH=. $(PYTHON) scripts/script_template_survey.py --state-path $(STATE_PATH) --scan-blocks $(SCAN_BLOCKS)

docker-build:
	$(DOCKER_COMPOSE) build pybitnode pybitnode-rocksdb-proof pybitnode-supporting-5k-proof pybitnode-supervisor pybitnode-supervisor-status

docker-warm: docker-build

docker-script-corpus:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(MAKE) docker-build; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	PYBITNODE_RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps \
	  -v $(abspath ../Shared/conformance):/shared/conformance \
	  pybitnode python -m pybitnode.conformance.script_corpus \
	  --manifest /shared/conformance/fixtures/scripts/manifest.json \
	  --result-path $(DOCKER_SCRIPT_RESULT)

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(MAKE) docker-build; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) PYBITNODE_BENCHMARK_RESULT=$(SUPPORTING_5K_RESULT) \
	  PYBITNODE_BENCHMARK_TARGET=$(DOCKER_BENCHMARK_TARGET) \
	  PYBITNODE_BENCHMARK_PEER=$(DOCKER_P2P_PEER) PYBITNODE_BENCHMARK_PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) \
	  PYBITNODE_BENCHMARK_SCRIPT_THREADS="$(DOCKER_SCRIPT_THREADS)" \
	  $(DOCKER_COMPOSE) run --rm pybitnode-supporting-5k-proof

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=pybitnode_10k_proof_data \
	  SUPPORTING_5K_RESULT=$(SUPPORTING_10K_RESULT) \
	  DOCKER_BENCHMARK_TARGET=10000

docker-python-rocksdb-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(MAKE) docker-build; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps pybitnode-rocksdb-proof

docker-python-supervisor:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) $(DOCKER_COMPOSE) up -d pybitnode-supervisor

docker-python-supervisor-status:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps pybitnode-supervisor-status

docker-python-supervisor-stop:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps pybitnode-supervisor-stop

docker-python-supervisor-resume:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) $(DOCKER_COMPOSE) run --rm --no-deps pybitnode-supervisor-resume
