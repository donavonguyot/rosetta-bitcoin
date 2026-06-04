JAVA_HOME ?= /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
MVN = JAVA_HOME="$(JAVA_HOME)" PATH="$(JAVA_HOME)/bin:$$PATH" mvn
MAVEN_OPTS ?= -Xmx4g -XX:+ExitOnOutOfMemoryError
export MAVEN_OPTS
DOCKER_PROOF_VOLUME ?= jbitnode_proof_data
DOCKER_BENCHMARK_RESULT ?= ../Shared/conformance/results/java_docker_supporting_5k_benchmark_$(shell date +%F).json
DOCKER_BENCHMARK_TARGET ?= 5000
DOCKER_BENCHMARK_BLOCKS_MAX ?= 5001
DOCKER_BENCHMARK_HEADERS_MAX ?= 10000
DOCKER_BENCHMARK_HEADER_BATCHES_MAX ?= 50
DOCKER_BENCHMARK_PREFETCH_DEPTH ?= 4
DOCKER_LONG_PROOF_VOLUME ?= jbitnode_native_long_sync_data
DOCKER_LONG_PROOF_PATH ?= ../Shared/conformance/results/java_native_crypto_docker_long_sync_2026-06-01.json
DOCKER_LONG_HEADERS_MAX ?= 10000
DOCKER_LONG_HEADER_BATCHES_MAX ?= 50
DOCKER_LONG_BLOCKS_MAX ?= 10000
DOCKER_SYNC_VOLUME ?= jbitnode_sync_data
DOCKER_SYNC_HEADERS_MAX ?= 10000
DOCKER_SYNC_HEADER_BATCHES_MAX ?= 50
DOCKER_SYNC_BLOCKS_MAX ?= 500
DOCKER_SYNC_POLL_SEC ?= 120
DOCKER_SYNC_CHECK_SEC ?= 5
DOCKER_COMPOSE = docker compose -f docker/docker-compose.yml
DOCKER_REBUILD ?= 0

.PHONY: test coverage docker-config docker-build docker-warm docker-java-sync-proof docker-java-native-crypto-proof docker-java-supporting-5k-proof docker-java-native-crypto-long-sync-proof docker-java-native-crypto-50k-sync-proof docker-java-native-crypto-tip-sync-proof docker-java-proof-status docker-java-sync-supervisor docker-java-sync-status docker-java-sync-stop docker-java-sync-resume java-node-status java-node-db-status java-node-native-status java-node-native-sync java-node-project-export java-node-preflight java-node-sync-local-core java-node-live java-node-sync-catchup java-node-sync-chunk java-node-sync-rocksdb java-node-sync-chunk-overnight java-node-sync-supervisor java-node-export-snapshots java-node-survey-scripts java-node-rocksdb-clean-rebuild java-node-native-crypto-test java-node-chainstate-backend-replay java-node-chainstate-backend-replay-native-crypto java-node-chainstate-backend-benchmark java-node-replay-corpus-export

test:
	$(MVN) test

coverage:
	$(MVN) verify

docker-config:
	$(DOCKER_COMPOSE) config

docker-build:
	$(DOCKER_COMPOSE) build jbitnode-sync-proof

docker-warm: docker-build

docker-java-sync-proof:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build jbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),pure_java) $(DOCKER_COMPOSE) run --rm jbitnode-sync-proof
	$(MAKE) docker-java-proof-status
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/jbitnode.db

docker-java-native-crypto-proof:
	$(MAKE) docker-java-supporting-5k-proof DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) SECP256K1_BACKEND=native

docker-java-supporting-5k-proof:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build jbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_PROOF_VOLUME) SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) \
	  DOCKER_BENCHMARK_TARGET=$(DOCKER_BENCHMARK_TARGET) DOCKER_BENCHMARK_BLOCKS_MAX=$(DOCKER_BENCHMARK_BLOCKS_MAX) \
	  DOCKER_BENCHMARK_HEADERS_MAX=$(DOCKER_BENCHMARK_HEADERS_MAX) DOCKER_BENCHMARK_HEADER_BATCHES_MAX=$(DOCKER_BENCHMARK_HEADER_BATCHES_MAX) \
	  DOCKER_BENCHMARK_PREFETCH_DEPTH=$(DOCKER_BENCHMARK_PREFETCH_DEPTH) DOCKER_BENCHMARK_RESULT=$(DOCKER_BENCHMARK_RESULT) \
	  scripts/docker_5k_benchmark.sh
	@docker run --rm -v $(DOCKER_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/jbitnode.db

docker-java-native-crypto-long-sync-proof:
	@for i in $$(seq 1 60); do \
	  nc -z 127.0.0.1 48333 && break; \
	  sleep 2; \
	  if [ "$$i" = "60" ]; then echo "error: host-published Core P2P port 48333 not reachable" >&2; exit 1; fi; \
	done
	@if [ "$(DOCKER_REBUILD)" = "1" ]; then $(DOCKER_COMPOSE) build jbitnode-sync-proof; else echo "docker image warm reuse; run 'make docker-warm' or DOCKER_REBUILD=1 to rebuild"; fi
	@docker volume rm -f $(DOCKER_LONG_PROOF_VOLUME) >/dev/null 2>&1 || true
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) SECP256K1_BACKEND=native \
	  HEADERS_MAX=$(DOCKER_LONG_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_LONG_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_LONG_BLOCKS_MAX) $(DOCKER_COMPOSE) run --rm jbitnode-sync-proof; echo $$? > .docker-java-native-long-sync-exit
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) SECP256K1_BACKEND=native \
	  HEADERS_MAX=$(DOCKER_LONG_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_LONG_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_LONG_BLOCKS_MAX) $(DOCKER_COMPOSE) run --rm --no-deps jbitnode-sync-proof com.jbitnode.cli.DbStatus > .docker-java-native-long-status.json
	DOCKER_PROOF_VOLUME=$(DOCKER_LONG_PROOF_VOLUME) \
	  TARGET_HEADER_HEIGHT=$(DOCKER_LONG_HEADERS_MAX) TARGET_BLOCK_HEIGHT=$(DOCKER_LONG_BLOCKS_MAX) \
	  LOCAL_REFERENCE_TIP_HEIGHT="$(LOCAL_REFERENCE_TIP_HEIGHT)" LOCAL_REFERENCE_TIP_HASH="$(LOCAL_REFERENCE_TIP_HASH)" \
	  PROOF_PATH=$(DOCKER_LONG_PROOF_PATH) PROOF_COMMAND="$(or $(PROOF_COMMAND),$(MAKE) docker-java-native-crypto-long-sync-proof)" \
	  python3 ../Shared/conformance/tools/proofs/capture_docker_native_long_sync_proof.py .docker-java-native-long-status.json .docker-java-native-long-sync-exit
	@rm -f .docker-java-native-long-status.json .docker-java-native-long-sync-exit
	@docker run --rm -v $(DOCKER_LONG_PROOF_VOLUME):/data alpine:3.20 test ! -f /data/jbitnode.db

docker-java-native-crypto-50k-sync-proof:
	$(MAKE) docker-java-native-crypto-long-sync-proof \
	  DOCKER_LONG_HEADERS_MAX=50000 \
	  DOCKER_LONG_HEADER_BATCHES_MAX=50 \
	  DOCKER_LONG_BLOCKS_MAX=50000 \
	  DOCKER_LONG_PROOF_VOLUME=jbitnode_native_50k_sync_data \
	  DOCKER_LONG_PROOF_PATH=../Shared/conformance/results/java_native_crypto_docker_50k_sync_2026-06-01.json \
	  PROOF_COMMAND="$(MAKE) docker-java-native-crypto-50k-sync-proof"

docker-java-native-crypto-tip-sync-proof:
	@LOCAL_TIP_HEIGHT=$$(docker exec rosetta-bitcoin-core-testnet4 bitcoin-cli -conf=/config/bitcoin.conf getblockchaininfo | python3 -c 'import json,sys; print(json.load(sys.stdin)["blocks"])'); \
	LOCAL_TIP_HASH=$$(docker exec rosetta-bitcoin-core-testnet4 bitcoin-cli -conf=/config/bitcoin.conf getblockchaininfo | python3 -c 'import json,sys; print(json.load(sys.stdin)["bestblockhash"])'); \
	TARGET=$$(python3 -c "print(max(140000, int('$$LOCAL_TIP_HEIGHT') + 1000))"); \
	echo "local_reference_tip_height=$$LOCAL_TIP_HEIGHT local_reference_tip_hash=$$LOCAL_TIP_HASH target=$$TARGET"; \
	$(MAKE) docker-java-native-crypto-long-sync-proof \
	  DOCKER_LONG_HEADERS_MAX=$$TARGET \
	  DOCKER_LONG_HEADER_BATCHES_MAX=100 \
	  DOCKER_LONG_BLOCKS_MAX=$$TARGET \
	  DOCKER_LONG_PROOF_VOLUME=jbitnode_native_tip_sync_data \
	  DOCKER_LONG_PROOF_PATH=../Shared/conformance/results/java_native_crypto_docker_tip_sync_2026-06-01.json \
	  LOCAL_REFERENCE_TIP_HEIGHT=$$LOCAL_TIP_HEIGHT \
	  LOCAL_REFERENCE_TIP_HASH=$$LOCAL_TIP_HASH \
	  PROOF_COMMAND="$(MAKE) docker-java-native-crypto-tip-sync-proof"

docker-java-proof-status:
	SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),pure_java) $(DOCKER_COMPOSE) run --rm --no-deps jbitnode-sync-proof com.jbitnode.cli.DbStatus

docker-java-sync-supervisor:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  HEADERS_MAX=$(DOCKER_SYNC_HEADERS_MAX) HEADER_BATCHES_MAX=$(DOCKER_SYNC_HEADER_BATCHES_MAX) \
	  BLOCKS_MAX=$(DOCKER_SYNC_BLOCKS_MAX) POLL_SEC=$(DOCKER_SYNC_POLL_SEC) CHECK_SEC=$(DOCKER_SYNC_CHECK_SEC) \
	  scripts/docker_sync_supervisor.sh

docker-java-sync-status:
	DOCKER_PROOF_VOLUME=$(DOCKER_SYNC_VOLUME) SECP256K1_BACKEND=native \
	  $(DOCKER_COMPOSE) run --rm --no-deps jbitnode-sync-proof com.jbitnode.cli.DbStatus

docker-java-sync-stop:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.jbitnode_supervisor_stop'

docker-java-sync-resume:
	docker run --rm -v $(DOCKER_SYNC_VOLUME):/data alpine:3.20 sh -c 'touch /data/.jbitnode_supervisor_resume'

java-node-db-status:
	@DATA_DIR=$(or $(DATA_DIR),./data-java) $(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.DbStatus

java-node-status:
	@DATA_DIR=$(or $(DATA_DIR),./data-java) $(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.DbStatus

java-node-native-status:
	@test ! -f "$(or $(DATA_DIR),./data-java-rocksdb)/jbitnode.db" || \
	  (echo "error: native datadir contains jbitnode.db" >&2; exit 1)
	@DATA_DIR=$(or $(DATA_DIR),./data-java-rocksdb) $(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.DbStatus
	@test ! -f "$(or $(DATA_DIR),./data-java-rocksdb)/jbitnode.db" || \
	  (echo "error: native status created jbitnode.db" >&2; exit 1)

java-node-project-export:
	@TMP=$$(mktemp); \
	DATA_DIR="$(or $(DATA_DIR),./data-java)" $(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.DbStatus > "$$TMP"; \
	python3 ../Project/scripts/import_status_snapshot.py --db "$(or $(PROJECT_DB),../Project/project.db)" --node-id "$(or $(NODE_ID),javanode)" "$$TMP"; \
	rm -f "$$TMP"

java-node-native-sync:
	DATA_DIR=$(or $(DATA_DIR),./data-java-rocksdb) UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java-rocksdb)/utxo-rocksdb) \
	PEERS=$(or $(PEERS),127.0.0.1:48333) BLOCKS_MAX=$(or $(BLOCKS_MAX),64) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore
	@test ! -f "$(or $(DATA_DIR),./data-java-rocksdb)/jbitnode.db" || \
	  (echo "error: native sync created jbitnode.db" >&2; exit 1)
	@test -f "$(or $(DATA_DIR),./data-java-rocksdb)/.jbitnode_native_storage" || \
	  (echo "error: native storage marker missing" >&2; exit 1)

# Fail if a sync process is already running; otherwise print DB status.
java-node-preflight:
	@pgrep -f '[c]om\.jbitnode\.cli\.SyncLocalCore' && exit 1 || true
	@DATA_DIR="$(or $(DATA_DIR),./data-java)"; \
	LOCK="$$DATA_DIR/.jbitnode.lock"; \
	if [ -f "$$LOCK" ]; then \
	  PID=$$(grep -E '^pid=' "$$LOCK" 2>/dev/null | head -1 | cut -d= -f2); \
	  if [ -n "$$PID" ] && kill -0 "$$PID" 2>/dev/null; then \
	    echo "error: datadir lock held by pid $$PID ($$LOCK)" >&2; exit 1; \
	  fi; \
	  echo "reclaiming stale lock $$LOCK" >&2; rm -f "$$LOCK"; \
	fi
	$(MAKE) java-node-db-status DATA_DIR=$(or $(DATA_DIR),./data-java)

java-node-sync-local-core:
	DATA_DIR=$(or $(DATA_DIR),./data-java) UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore

java-node-live:
	HEADERS_MAX=$(or $(HEADERS_MAX),2000) HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),64) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	PAR_SCRIPT_VERIFY=1 SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) \
	DATA_DIR=$(or $(DATA_DIR),./data-java) UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	SYNC_TIMING=$(or $(SYNC_TIMING),1) LIVE_POLL_MS=$(or $(LIVE_POLL_MS),30000) \
	LIVE_RECONNECT_MS=$(or $(LIVE_RECONNECT_MS),5000) LIVE_MAX_ITERATIONS=$(or $(LIVE_MAX_ITERATIONS),0) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.LiveNode

# Extended catch-up toward testnet4 height 6975+ (headers past 7100, unlimited blocks until blocker).
java-node-sync-catchup:
	HEADERS_MAX=$(or $(HEADERS_MAX),10000) HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),0) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) DATA_DIR=$(or $(DATA_DIR),./data-java) \
	UTXO_BACKEND=rocksdb ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore

# Normal catch-up ops: 5000-block chunk from validated tip (manual re-run after status + snapshots).
# Override: make java-node-sync-chunk BLOCKS_MAX=10000
java-node-sync-chunk:
	HEADERS_MAX=$(or $(HEADERS_MAX),10000) HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),5000) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	PAR_SCRIPT_VERIFY=1 SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) DATA_DIR=$(or $(DATA_DIR),./data-java) \
	UTXO_BACKEND=rocksdb ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore

java-node-sync-rocksdb:
	HEADERS_MAX=$(or $(HEADERS_MAX),10000) HEADER_BATCHES_MAX=$(or $(HEADER_BATCHES_MAX),50) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),5000) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	PAR_SCRIPT_VERIFY=1 SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) \
	DATA_DIR=$(or $(DATA_DIR),./data-java) UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	SYNC_TIMING=$(or $(SYNC_TIMING),1) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.SyncLocalCore

# Long unattended chunk (~6–8 h at current PAR_SCRIPT_VERIFY=1 rates). Same single-writer rules.
# Override: make java-node-sync-chunk-overnight BLOCKS_MAX=25000
java-node-sync-chunk-overnight:
	$(MAKE) java-node-sync-chunk BLOCKS_MAX=$(or $(BLOCKS_MAX),15000) \
	  DATA_DIR=$(or $(DATA_DIR),./data-java) PEERS=$(or $(PEERS),127.0.0.1:48333)

# Durable supervisor: sub-chunks + crash restart + stop file (see scripts/sync_supervisor.sh).
java-node-sync-supervisor:
	CHUNK_TOTAL=$(or $(CHUNK_TOTAL),15000) SUBCHUNK_SIZE=$(or $(SUBCHUNK_SIZE),500) \
	  DATA_DIR=$(or $(DATA_DIR),./data-java) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	  ./scripts/sync_supervisor.sh

java-node-export-snapshots:
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.ExportSnapshots

java-node-survey-scripts:
	@echo "java-node-survey-scripts moved out of Java runtime SQLite scope" >&2; exit 2

java-node-rocksdb-clean-rebuild:
	DATA_DIR=$(or $(DATA_DIR),./data-java) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	CHAINSTATE_REBUILD=1 UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java)/utxo-rocksdb) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),5000) PAR_SCRIPT_VERIFY=1 \
	SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),native) SYNC_TIMING=$(or $(SYNC_TIMING),1) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.ChainstateRebuild

java-node-native-crypto-test:
	SECP256K1_BACKEND=native $(MVN) test

java-node-chainstate-backend-replay:
	DATA_DIR=$(or $(DATA_DIR),./data-java-rocksdb-replay) UTXO_BACKEND=rocksdb \
	ROCKSDB_DIR=$(or $(ROCKSDB_DIR),$(or $(DATA_DIR),./data-java-rocksdb-replay)/utxo-rocksdb) \
	FIXTURE_BLOCKS_DIR=$(or $(FIXTURE_BLOCKS_DIR),src/test/resources/fixtures) \
	REPLAY_CORPUS_DIR=$(REPLAY_CORPUS_DIR) \
	PROOF_PATH=$(or $(PROOF_PATH),../Shared/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json) \
	SECP256K1_BACKEND=$(or $(SECP256K1_BACKEND),pure_java) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),2) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.ChainstateBackendReplay

java-node-chainstate-backend-replay-native-crypto:
	$(MAKE) java-node-chainstate-backend-replay SECP256K1_BACKEND=native \
	  DATA_DIR=$(or $(DATA_DIR),./data-java-native-crypto-replay-$$(date +%Y%m%d%H%M%S)) \
	  PROOF_PATH=$(or $(PROOF_PATH),../Shared/conformance/results/java_native_crypto_host_replay_2026-06-01.json)

java-node-replay-corpus-export:
	SOURCE_DATA_DIR=$(or $(SOURCE_DATA_DIR),./data-java) \
	FIXTURE_BLOCKS_DIR=$(FIXTURE_BLOCKS_DIR) \
	REPLAY_CORPUS_DIR=$(or $(REPLAY_CORPUS_DIR),../Shared/replay-corpus/testnet4) \
	REPLAY_CORPUS_ID=$(or $(REPLAY_CORPUS_ID),testnet4-h1-$(or $(BLOCKS_MAX),100)) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),100) \
	$(MVN) -q -DskipTests exec:java -Dexec.mainClass=com.jbitnode.cli.ReplayCorpusExport

java-node-chainstate-backend-benchmark:
	SOURCE_DATA_DIR=$(or $(SOURCE_DATA_DIR),./data-java) \
	WORK_DIR=$(or $(WORK_DIR),./benchmark-chainstate) \
	BLOCKS_MAX=$(or $(BLOCKS_MAX),500) PEERS=$(or $(PEERS),127.0.0.1:48333) \
	./scripts/chainstate_backend_replay_benchmark.sh
