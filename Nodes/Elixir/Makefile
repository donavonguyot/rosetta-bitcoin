MIX ?= mix
DATA_DIR ?= ./data-elixir
PEERS ?= 127.0.0.1:48333
DOCKER_COMPOSE ?= docker compose -f docker/docker-compose.yml
REFERENCE_DOCKER_NETWORK ?= rosetta-reference-node_default
DOCKER_PEERS ?= bitcoin-core-testnet4:48333
DOCKER_REBUILD ?= 0
DOCKER_PROOF_VOLUME ?= exbitnode_proof_data
DOCKER_SYNC_VOLUME ?= exbitnode_sync_data
DOCKER_PROOF_PATH ?= ../Shared/conformance/results/elixir_rocksdb_codec_v2_storage.json
RESULT_DATE ?= $(shell date +%F)
DOCKER_BENCHMARK_RESULT ?= ../Shared/conformance/results/elixir_docker_baseline_5k_benchmark_$(RESULT_DATE).json
DOCKER_10K_BENCHMARK_RESULT ?= ../Shared/conformance/results/elixir_docker_diagnostic_10k_benchmark_$(RESULT_DATE).json
DOCKER_50K_BENCHMARK_RESULT ?= ../Shared/conformance/results/elixir_docker_shakedown_50k_benchmark_$(RESULT_DATE).json
DOCKER_BENCHMARK_TARGET ?= 5000
DOCKER_BENCHMARK_HEADER_TARGET ?= $(DOCKER_BENCHMARK_TARGET)
DOCKER_BENCHMARK_BLOCKS_MAX ?= 5001
DOCKER_SCRIPT_RESULT ?= /shared/conformance/results/elixir_script_corpus_docker_$(RESULT_DATE).json
DOCKER_PREFETCH_DEPTH ?= 0
DOCKER_SCRIPT_THREADS ?= 4
DOCKER_LONG_PROOF_VOLUME ?= exbitnode_native_10k_sync_data
DOCKER_LONG_PROOF_PATH ?= ../Shared/conformance/results/elixir_native_docker_10k_sync_20260603.json
DOCKER_LONG_HEADERS_MAX ?= 10000
DOCKER_LONG_HEADER_BATCHES_MAX ?= 50
DOCKER_LONG_BLOCKS_MAX ?= 10000
DOCKER_LONG_TARGET_HEADER_HEIGHT ?= $(DOCKER_LONG_HEADERS_MAX)
DOCKER_LONG_TARGET_BLOCK_HEIGHT ?= $(DOCKER_LONG_BLOCKS_MAX)
DOCKER_HEADERS_MAX ?= 200
DOCKER_HEADER_BATCHES_MAX ?= 1
DOCKER_BLOCKS_MAX ?= 2
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5
REFERENCE_P2P_CHECK = docker run --rm --network $(REFERENCE_DOCKER_NETWORK) -v $(abspath ../Shared/docker):/shared/docker:ro python:3.12-alpine python3 /shared/docker/check_reference_p2p.py --peer $(DOCKER_PEERS)

.PHONY: test status node-status sync-local storage-proof script-corpus docker-config docker-build docker-warm docker-status docker-storage-proof docker-script-corpus docker-proof-local docker-proof-10k docker-proof-50k docker-long-sync-proof docker-10k-sync-proof docker-supervisor docker-supervisor-status docker-supervisor-stop docker-supervisor-resume docker-smoke-once clean

test:
	$(MIX) test

status:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) $(MIX) status

node-status: status

sync-local:
	DATA_DIR=$(DATA_DIR) PEERS=$(PEERS) HEADERS_MAX=$(or $(HEADERS_MAX),2000) \
	HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),128) SKIP_BLOCKS=$(SKIP_BLOCKS) \
	$(MIX) sync.local

storage-proof:
	DATA_DIR=$(DATA_DIR) PROOF_PATH=$(or $(PROOF_PATH),../Shared/conformance/results/elixir_rocksdb_codec_v2_storage.json) $(MIX) storage.proof

script-corpus:
	$(MIX) script.corpus -- --manifest $(or $(MANIFEST),../Shared/conformance/fixtures/scripts/manifest.json) --result-path $(or $(RESULT_PATH),../Shared/conformance/results/elixir_script_corpus.json)

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build exbitnode-sync-proof

docker-warm: docker-build

docker-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status

docker-storage-proof:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build exbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) RUNTIME_SURFACE=docker PROOF_PATH=/tmp/elixir_storage_proof.json \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix storage.proof

docker-script-corpus:
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build exbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	RUNTIME_SURFACE=docker $(DOCKER_COMPOSE) run --rm --no-deps \
	  -v $(abspath ../Shared/conformance):/shared/conformance \
	  exbitnode-sync-proof mix script.corpus -- \
	  --manifest /shared/conformance/fixtures/scripts/manifest.json \
	  --result-path $(DOCKER_SCRIPT_RESULT)

docker-proof-local:
	$(REFERENCE_P2P_CHECK)
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build exbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	@set -e; \
	  sync_log=.docker-elixir-5k-sync.log; \
	  status_json=.docker-elixir-5k-status.json; \
	  exit_file=.docker-elixir-5k-sync-exit; \
	  set +e; \
	  DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) RUNTIME_SURFACE=docker PEERS=$(DOCKER_PEERS) \
		    HEADERS_MAX=$(DOCKER_BENCHMARK_HEADER_TARGET) HEADER_BATCHES_MAX=50 BLOCKS_MAX=$(DOCKER_BENCHMARK_BLOCKS_MAX) \
	    BLOCK_PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) SYNC_TIMING=1 \
	    SYNC_SNAPSHOT_SEC=$(or $(SYNC_SNAPSHOT_SEC),5) SYNC_SNAPSHOT_BLOCKS=$(or $(SYNC_SNAPSHOT_BLOCKS),0) \
	    PAR_SCRIPT_VERIFY=1 PAR_SCRIPT_THREADS=$(DOCKER_SCRIPT_THREADS) PAR_SCRIPT_MIN_INPUTS=2 \
	    $(DOCKER_COMPOSE) run --rm exbitnode-sync-proof mix sync.local > $$sync_log 2>&1; \
	  sync_rc=$$?; \
	  set -e; \
	  printf '%s\n' "$$sync_rc" > $$exit_file; \
	  DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) RUNTIME_SURFACE=docker PEERS=$(DOCKER_PEERS) \
	    $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status > $$status_json || true; \
		  DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) TARGET_HEIGHT=$(DOCKER_BENCHMARK_TARGET) HEADER_TARGET_HEIGHT=$(DOCKER_BENCHMARK_HEADER_TARGET) \
		    BLOCKS_MAX=$(DOCKER_BENCHMARK_BLOCKS_MAX) PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) SCRIPT_RUNNER_MODE=parallel \
	    PEER=$(DOCKER_PEERS) PROOF_PATH=$(DOCKER_BENCHMARK_RESULT) \
	    python3 ../Shared/conformance/tools/proofs/capture_elixir_docker_5k_benchmark.py $$status_json $$sync_log $$exit_file; \
	  rm -f $$sync_log $$status_json $$exit_file

docker-proof-10k:
	$(MAKE) docker-proof-local \
	  DOCKER_PROOF_VOLUME=exbitnode_10k_proof_data \
	  DOCKER_BENCHMARK_RESULT=$(DOCKER_10K_BENCHMARK_RESULT) \
	  DOCKER_BENCHMARK_TARGET=10000 \
	  DOCKER_BENCHMARK_HEADER_TARGET=10000 \
	  DOCKER_BENCHMARK_BLOCKS_MAX=10001

docker-proof-50k:
	$(REFERENCE_P2P_CHECK)
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build exbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f exbitnode_50k_proof_data >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=exbitnode_50k_proof_data RUNTIME_SURFACE=docker \
	  PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=50000 HEADER_BATCHES_MAX=100 BLOCKS_MAX=50001 \
	  TARGET_BLOCK_HEIGHT=50000 BENCHMARK_GATE=shakedown_50k \
	  BLOCK_PREFETCH_DEPTH=4 SYNC_TIMING=1 \
	  SYNC_SNAPSHOT_SEC=$(or $(SYNC_SNAPSHOT_SEC),5) \
	  SYNC_SNAPSHOT_BLOCKS=$(or $(SYNC_SNAPSHOT_BLOCKS),0) \
	  PAR_SCRIPT_VERIFY=1 PAR_SCRIPT_THREADS=$(DOCKER_SCRIPT_THREADS) PAR_SCRIPT_MIN_INPUTS=2 \
	  POLL_SEC=$(or $(POLL_SEC),30) CHECK_SEC=$(or $(CHECK_SEC),5) \
	  SUPERVISOR_ONCE=1 scripts/docker_sync_supervisor.sh || true
	@docker run --rm -v exbitnode_50k_proof_data:/data alpine:3.20 sh -c 'cat /data/.exbitnode_last_sync_exit 2>/dev/null || echo 0' > .docker-elixir-50k-sync-exit
	DOCKER_PROOF_VOLUME=exbitnode_50k_proof_data RUNTIME_SURFACE=docker PEERS=$(DOCKER_PEERS) \
	  BLOCK_PREFETCH_DEPTH=4 SYNC_TIMING=1 \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status > .docker-elixir-50k-status.json || true
	DOCKER_PROOF_VOLUME=exbitnode_50k_proof_data TARGET_HEIGHT=50000 HEADER_TARGET_HEIGHT=50000 \
	  BLOCKS_MAX=50001 PREFETCH_DEPTH=4 SCRIPT_RUNNER_MODE=parallel \
	  PEER=$(DOCKER_PEERS) PROOF_PATH=$(DOCKER_50K_BENCHMARK_RESULT) \
	  python3 ../Shared/conformance/tools/proofs/capture_elixir_docker_5k_benchmark.py .docker-elixir-50k-status.json /dev/null .docker-elixir-50k-sync-exit
	@rm -f .docker-elixir-50k-status.json .docker-elixir-50k-sync-exit

docker-long-sync-proof:
	$(REFERENCE_P2P_CHECK)
	@docker volume rm -f $(DOCKER_LONG_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) RUNTIME_SURFACE=docker_supervisor \
	  PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=$(DOCKER_LONG_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_LONG_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_LONG_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  BLOCK_PREFETCH_DEPTH=$(DOCKER_PREFETCH_DEPTH) SYNC_TIMING=1 \
	  SYNC_SNAPSHOT_SEC=$(or $(SYNC_SNAPSHOT_SEC),5) \
	  SYNC_SNAPSHOT_BLOCKS=$(or $(SYNC_SNAPSHOT_BLOCKS),0) \
	  SUPERVISOR_ONCE=1 scripts/docker_sync_supervisor.sh || true
	@docker run --rm -v $(DOCKER_LONG_PROOF_VOLUME):/data alpine:3.20 sh -c 'cat /data/.exbitnode_last_sync_exit 2>/dev/null || echo 0' > .docker-elixir-long-sync-exit
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) RUNTIME_SURFACE=docker \
	  PEERS=$(DOCKER_PEERS) \
	  $(DOCKER_COMPOSE) run --rm --no-deps exbitnode-sync-proof mix node.status > .docker-elixir-long-status.json || true
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) \
	  TARGET_HEADER_HEIGHT=$(DOCKER_LONG_TARGET_HEADER_HEIGHT) TARGET_BLOCK_HEIGHT=$(DOCKER_LONG_TARGET_BLOCK_HEIGHT) \
	  PROOF_PATH=$(DOCKER_LONG_PROOF_PATH) PROOF_COMMAND="$(or $(PROOF_COMMAND),$(MAKE) docker-long-sync-proof)" \
	  python3 ../Shared/conformance/tools/proofs/capture_elixir_docker_long_sync_proof.py .docker-elixir-long-status.json .docker-elixir-long-sync-exit
	@rm -f .docker-elixir-long-status.json .docker-elixir-long-sync-exit

docker-10k-sync-proof:
	$(MAKE) docker-long-sync-proof \
	  DOCKER_LONG_HEADERS_MAX=10000 \
	  DOCKER_LONG_HEADER_BATCHES_MAX=50 \
	  DOCKER_LONG_BLOCKS_MAX=10001 \
	  DOCKER_LONG_TARGET_HEADER_HEIGHT=10000 \
	  DOCKER_LONG_TARGET_BLOCK_HEIGHT=10000 \
	  DOCKER_LONG_PROOF_VOLUME=exbitnode_native_10k_sync_data \
	  DOCKER_LONG_PROOF_PATH=../Shared/conformance/results/elixir_native_docker_10k_sync_20260603.json \
	  PROOF_COMMAND="$(MAKE) docker-10k-sync-proof"

docker-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-supervisor-status:
	@$(MAKE) docker-status || true

docker-supervisor-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_stop'

docker-supervisor-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.exbitnode_supervisor_resume'

docker-smoke-once:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) PEERS=$(DOCKER_PEERS) \
	  HEADERS_MAX=0 HEADER_BATCHES_MAX=0 BLOCKS_MAX=0 POLL_SEC=1 CHECK_SEC=1 SUPERVISOR_ONCE=1 \
	  scripts/docker_sync_supervisor.sh

clean:
	$(MIX) clean
	rm -rf _build deps data-elixir-smoke
