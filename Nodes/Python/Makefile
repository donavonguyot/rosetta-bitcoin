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

SYNC_ENV = MAX_OUTBOUND_PEERS=1 PARALLEL_BLOCK_DOWNLOADS=0 SKIP_GETADDR=1

.PHONY: python-node-status python-node-preflight python-node-rocksdb-proof docker-python-rocksdb-proof docker-python-supervisor docker-python-supervisor-status docker-python-supervisor-stop docker-python-supervisor-resume python-node-sync-local-reference python-node-sync-chunk python-node-sync-chunk-overnight python-node-sync-supervisor python-node-export-snapshots python-node-survey-scripts test

test:
	$(PYTHON) -m pytest -q

python-node-status:
	$(PYBITNODE_DB) --state-path $(STATE_PATH)

python-node-rocksdb-proof:
	$(PYBITNODE_ROCKSDB_PROOF) --datadir $(DATA_DIR)-proof --proof-path $(DOCKER_PROOF_PATH)

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

docker-python-rocksdb-proof:
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-rocksdb-proof

docker-python-supervisor:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) docker compose -f docker/docker-compose.yml up -d pybitnode-supervisor

docker-python-supervisor-status:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-supervisor-status

docker-python-supervisor-stop:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-supervisor-stop

docker-python-supervisor-resume:
	DOCKER_SUPERVISOR_VOLUME=$(DOCKER_SUPERVISOR_VOLUME) docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-supervisor-resume
