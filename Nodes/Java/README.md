# jbitnode — Java 21 Bitcoin testnet4 full node

**jbitnode** is a clean Java follower for the Nodes workspace. Known consensus
rules come from the Shared rule ledger and script corpus; jbitnode implements
those rules independently and must reach tip with fully validated connected
blocks.

## Binary gate

From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block. Partial sync,
headers-only sync, trusted import, or skipping unknown consensus rules does
**not** pass.

Current Java evidence includes RocksDB/native chainstate proofs, native
secp256k1 proofs, 10k and 50k Docker native-crypto bounded sync proofs, and a
Core-aligned local run recorded at `validated_height=136863` with
`binary_gate_status=passed`. Tip maintenance and serving behavior remain
separate operational work.

## Datadir and database

| Item | Default |
|------|---------|
| Datadir | `./data-java/` (gitignored) |
| Active chainstate | RocksDB under `./data-java/chainstate-rocksdb/` |
| Chain | `testnet4` (`CHAIN` env override) |

Override paths with `DATA_DIR` or proof-specific environment variables. **One
writer per datadir** — never share DB files or native chainstate directories
with another node or another Java process.

Sync acquires an exclusive lock at `<DATA_DIR>/.jbitnode.lock`. A second
`make java-node-sync-local-core` / `java-node-sync-catchup` against the same
datadir exits with `datadir lock busy` until the first process finishes.

### Recovery (missing UTXO / inconsistent chain)

Intermittent `ConnectBlockException: missing UTXO` during long catch-up is
almost always **parallel sync writers** on one datadir (for example two
`BLOCKS_MAX=0` runs). One connect spends outputs; the other fails mid-block.

Before resuming sync:

1. Stop **all** jbitnode sync processes (`ps aux | grep SyncLocalCore`).
2. Run `make java-node-status` — `validated_height` must equal stored
   `block_count` with no gaps below the tip.
3. If `ChainInconsistentException` is reported, rebuild from a clean datadir:

```bash
mv ./data-java ./data-java.bak-$(date +%Y%m%d)
make java-node-sync-catchup   # headers + blocks from genesis
```

Or restore a known-good backup instead of full re-sync.

## Coverage gate

Every build runs JaCoCo during `mvn verify`. **Line coverage must be 100%** on
all non-excluded production code or the build fails.

Tiny JaCoCo exclusions (documented in `pom.xml`):

- `com.jbitnode.cli.DbStatus` — `main()` shim only; logic lives in `DbStatusService`
- `com.jbitnode.cli.SyncLocalCore` — `main()` shim only; logic lives in `SyncLocalCoreService`
- `com.jbitnode.cli.ExportSnapshots` — `main()` shim only; logic lives in `ExportSnapshotsService`
- `com.jbitnode.cli.ScriptTemplateSurvey` — `main()` shim only; logic lives in `ScriptTemplateSurveyService`

Run locally:

```bash
make test       # mvn test
make coverage   # mvn verify (includes JaCoCo check)
```

Report: `target/site/jacoco/index.html`

## Deferred handshake (implemented)

Initial sync mirrors the workspace deferred-handshake posture:

1. Simple handshake: `version` → `verack` → **`sendheaders` only**.
2. **No** `feefilter`, `mempool`, or `sendcmpct` immediately after `verack`.
3. Those messages stay deferred until `sync_status === "headers_current"` and live LISTEN mode (future milestone).
4. **Honest `start_height`**: advertises `validated_tip` height (0 when unset), never the header tip with zero validated blocks.

## Local Bitcoin Core peer

Reference Core (testnet4) for development:

| Service | Address |
|---------|---------|
| P2P | `127.0.0.1:48333` |
| RPC | `127.0.0.1:48332` |
| Core datadir | `~/NodeData/bitcoin-core-testnet4` |

Start Core via compose (from this directory):

```bash
docker compose -f docker/docker-compose.yml up -d bitcoin-core-testnet4
make docker-config   # validate compose file
```

The `jbitnode` service connects to host Core at `host.docker.internal:48333`
(OrbStack / Docker Desktop on macOS).

Host JVM sync and container sync are separate verification gates. Host `mvn`
or Make runs prove the Java code path on the workstation. `docker-java-sync-proof`
is a fast 2-block packaging smoke from a fresh Docker volume.
`docker-java-native-crypto-proof` is the Project-facing supporting 5k Docker
benchmark with native secp256k1, WAL enabled, and a fresh proof volume.
`docker-java-native-crypto-long-sync-proof` targets 10,000 headers and 10,000
connected blocks by default, and records either target reach or the exact next
blocker in a Shared proof artifact. `docker-java-native-crypto-50k-sync-proof`
is the next larger bounded gate, using a separate Docker volume and proof
artifact to test validation through height 50,000 without overwriting the 10k
evidence. `docker-java-native-crypto-tip-sync-proof` queries the local Core tip
before it starts, syncs from a fresh Docker volume with a height buffer, and
writes a full local-reference proof artifact with the recorded Core tip height
and hash.

Use the persistent Docker supervisor for iterative blocker hunting. It reuses
`jbitnode_sync_data` by default, emits `AGENT_LOOP_TICK_chatreport` from inside
Docker, pauses on blocker/error, and resumes from the same volume after a code
change or explicit resume marker. `POLL_SEC` controls operator/chat reports;
`CHECK_SEC` controls fast chunk-completion checks so the report cadence does not
throttle chunk turnover.

```bash
make docker-java-sync-supervisor
make docker-java-sync-status
make docker-java-sync-resume   # optional explicit resume trigger after a fix
make docker-java-sync-stop     # stop supervisor without deleting state
```

For a short smoke of the supervisor loop:

```bash
DOCKER_SYNC_VOLUME=jbitnode_sync_smoke_data DOCKER_SYNC_BLOCKS_MAX=2 \
  DOCKER_SYNC_POLL_SEC=10 DOCKER_SYNC_CHECK_SEC=2 make docker-java-sync-supervisor
```

Fresh proof targets still delete/recreate their proof volumes. Do not use those
targets as the normal blocker-hunting loop.

## Make targets

| Target | Purpose |
|--------|---------|
| `make test` | Run JUnit 5 tests |
| `make coverage` | Run tests + JaCoCo 100% line gate |
| `make docker-config` | Validate `docker-compose.yml` |
| `make docker-warm` | Warm the Docker image/cache before a benchmark campaign |
| `make docker-java-sync-proof` | Run a 2-block Docker packaging smoke against local Core from a fresh RocksDB proof volume |
| `make docker-java-native-crypto-proof` | Run the supporting 5k Docker benchmark with `SECP256K1_BACKEND=native` |
| `make docker-java-native-crypto-long-sync-proof` | Run the long Docker native crypto proof (`HEADERS_MAX=10000`, `BLOCKS_MAX=10000`) into a distinct proof artifact |
| `make docker-java-native-crypto-50k-sync-proof` | Run the 50k Docker native crypto proof into `java_native_crypto_docker_50k_sync_2026-06-01.json` |
| `make docker-java-native-crypto-tip-sync-proof` | Run the fresh Docker native crypto proof through the current local Core tip |
| `make docker-java-proof-status` | Inspect the Docker proof volume with `DbStatus` inside the Java image |
| `make docker-java-sync-supervisor` | Persistent Docker blocker-hunting loop with status ticks and pause/resume |
| `make docker-java-sync-status` | Inspect the persistent Docker supervisor volume |
| `make docker-java-sync-stop` | Request graceful supervisor stop without deleting state |
| `make docker-java-sync-resume` | Request resume from a paused supervisor after a fix |
| `make java-node-native-crypto-test` | Run the Java test suite with ACINQ native crypto selected |
| `make java-node-status` | Print JSON tracker summary (`DbStatus`) |
| `make java-node-db-status` | Same as status — JSON only, no Makefile recipe noise (for scripts) |
| `make java-node-preflight` | Fail if sync already running; reclaim stale `.jbitnode.lock` by pid |
| `make java-node-sync-chunk` | **Normal catch-up:** 5000 blocks from validated tip (`PAR_SCRIPT_VERIFY=1`; override `BLOCKS_MAX=`) |
| `make java-node-sync-chunk-overnight` | **Single-shot overnight:** 15000 blocks (override `BLOCKS_MAX=`; same single-writer rules) |
| `make java-node-sync-supervisor` | **Durable unattended catch-up:** sub-chunks of 500, auto-restart on crash/stall (see below) |
| `make java-node-sync-local-core` | Handshake + header sync + block download/connect against local Core |
| `make java-node-chainstate-backend-replay-native-crypto` | Run the RocksDB replay proof with `SECP256K1_BACKEND=native` |
| `make java-node-sync-catchup` | Rare unlimited catch-up (`BLOCKS_MAX=0` default; debug only) |
| `make java-node-export-snapshots` | Retired legacy exporter; native snapshot export is not implemented |
| `make java-node-survey-scripts` | Retired legacy survey; native script-template survey is not implemented |

## Proof tiers

| Tier | Artifact / target |
|------|-------------------|
| 2-block smoke | `docker-java-sync-proof` |
| Supporting 5k Docker benchmark | `java_docker_supporting_5k_benchmark_<date>.json`, `docker-java-native-crypto-proof` |
| Codec v2 replay | `java_rocksdb_codec_v2_storage_2026-06-01.json`, `java_rocksdb_codec_v2_storage_shared_2026-06-01.json` |
| Native crypto gate | `java_native_crypto_host_replay_2026-06-01.json` and local native-vector tests |
| 10k supporting Docker benchmark | `java_docker_supporting_10k_benchmark_<date>.json`, `docker-java-supporting-10k-proof` |
| 50k bounded Docker sync | `java_native_crypto_docker_50k_sync_2026-06-01.json` |
| Binary gate attempt/status | `docs/BLOCKER_LEDGER.md` records `validated_height=136863`, `binary_gate_status=passed` against local Core |

## Script interpreter

Package `com.jbitnode.consensus.script` provides opcode constants, a stack machine,
legacy, SegWit v0, Taproot key-path, and Taproot script-path validation needed
by the recorded live blocker trail.

| Status | Detail |
|--------|--------|
| Implemented | P2PK/P2PKH/P2WPKH, P2SH, P2WSH, P2TR key-path, P2TR script-path, CLTV/CSV, and live blocker opcode trail through 136369 |
| Regression | Fixtures under `src/test/resources/fixtures/` named by height/rule |
| Next | Tip maintenance, serving, and continued blocker capture from current network tip |

Historical reference fix: Python commit **`dd65c78`** (*Verify Taproot key-path spends*).
See `docs/BLOCKER_LEDGER.md` for blocker provenance and binary-gate evidence.

## Retired Compatibility Snapshot Export

The compatibility snapshot exporter is retired for Java native runtime. It
remains as a CLI stub that returns unsupported status so old scripts fail loudly
instead of reading or creating a port-local operational DB as runtime truth.

```bash
make java-node-export-snapshots
```

Use `make java-node-status` for current RocksDB-backed status and Project import
surfaces for mission-control snapshots.

## Retired Script Template Survey

The Java-local compatibility script survey is also retired. Shared consensus
readiness now starts from the rule ledger, the 45-fixture script corpus, and
Project consensus runway reports.

```bash
make java-node-survey-scripts
```

Use `Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`,
`Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json`, and Project
preflights before chasing live blockers.

## Post-sync operations checklist

After initial catch-up reaches or passes tip, JavaNode is not full-node ready until
these behaviors are proven against live peers and temp-datadir regressions:

| Area | Current status | Remaining work |
|------|----------------|----------------|
| Persist validated tip | `validated_tip` is advanced transactionally with UTXO updates and block metadata during block sync | Live proof after reaching current network tip |
| Restart at tip | Startup advertises `validated_tip` via honest `start_height`; tests cover restart state from a temp DB | Long-running restart-at-tip soak with no replay |
| Tip maintenance | Batch sync can mark `headers_current` / `blocks_current` | Continuous new-block loop and inv-driven catch-up |
| Invalid data safety | Invalid headers/blocks stop without advancing tip; blockers are logged in `events` | Peer scoring / ban policy for repeat invalid data |
| Undo data | `utxo_undo` rows are persisted for external spends | Disconnect/reconnect implementation that consumes undo rows |
| Reorgs | No reorg disconnect path yet | Fork storage, chainwork fork choice, disconnect/reconnect tests |
| Serving | Outbound `getheaders`/`getdata` client exists | Inbound `getheaders`/`getdata` serving to peers |
| Peer lifecycle | Connect/disconnect rows are recorded | Reconnect/backoff manager and peer rotation |
| Health output | `java-node-status` reports header/validated/stored heights, gaps, blocker, and binary gate status | Stable operator-facing health contract after live tip |

### Live datadir safety

- Do not run a second writer against `./data-java` while live sync is active.
- Do not stop the live Java sync process to inspect state.
- Use temp `DATA_DIR` values for tests and mock-peer sync checks.
- Prefer status-only tools for live inspection:

```bash
make java-node-status
```

`java-node-status` reads the native RocksDB-backed operational state. The
retired snapshot and survey targets are not native inspection tools.

### Diagnosing a blocked height

1. Run `make java-node-status` and record `validated_height`, `header_height`,
   `stored_block_height`, `block_gap_count`, `sync.sync_status`, and
   `current_blocker`.
2. If `block_gap_count > 0` or `stored_block_height < validated_height`, stop all
   Java writers for that datadir and follow the recovery section above.
3. If `current_blocker` identifies a consensus failure, harvest exact blocker
   facts: height, block hash, txid, input index, spent scriptPubKey, failure, and
   missing rule.
4. Add a fixture/regression test for the exact missing rule before resuming sync.
5. Use the Shared consensus rule ledger and script corpus as the first hint
   about known spend templates; do not treat Core/Python/Java as a validation
   oracle.

### Optional timing diagnostics

For low-noise performance diagnosis around hot sync regions, enable timing events
only on temp datadirs or deliberate diagnostic runs:

```bash
SYNC_TIMING=1 DATA_DIR=/tmp/jbitnode-timing make java-node-sync-local-core
```

Timing events are written to the `events` table with source `timing` for:
`block_download_wait`, `utxo_load`, `script_verify`, `utxo_apply`, `commit`, and
`block_connect_store_commit`.

## Catch-up workflow

### Manual chunks (5000 blocks)

Normal progress toward tip uses **manual 5000-block chunks** — one `SyncLocalCore` process per chunk.

```bash
make java-node-preflight
make java-node-sync-chunk DATA_DIR=./data-java PEERS=127.0.0.1:48333 \
  2>&1 | tee sync_chunk.log
make java-node-status
# repeat make java-node-sync-chunk until ValidationBlocker or tip
```

### Durable supervisor (recommended for unattended runs)

For overnight or long catch-up, use the supervisor instead of a single large chunk.
It runs **500-block sub-chunks** (default), auto-restarts on crash or `blocks_stalled`,
polls DB every 2 minutes, and **exits for an agent** on `ValidationBlocker` (exit code 2).

```bash
make java-node-preflight
make java-node-sync-supervisor DATA_DIR=./data-java PEERS=127.0.0.1:48333 \
  2>&1 | tee -a sync_chunk_auto.log
# stop cleanly: touch data-java/.stop_sync
```

| Env var | Default | Meaning |
|---------|---------|---------|
| `CHUNK_TOTAL` | `15000` | Total blocks per supervisor session |
| `SUBCHUNK_SIZE` | `500` | `BLOCKS_MAX` per inner `SyncLocalCore` run |
| `MAX_RESTARTS` | `5` | Restarts after crash/stall before exit 3 |
| `PROGRESS_STALL_SEC` | `900` | No height progress → SIGTERM child / stuck exit |

**Supervisor exit codes:** `0` = chunk cap or stop file; `2` = `blocks_blocked` (harvest/fix/resume);
`3` = stuck after restarts. Inner `SyncLocalCore` uses exit `4` on blocker and sets
`blocks_stalled` via shutdown hook on abnormal JVM exit.

**Stop file:** create `data-java/.stop_sync` between sub-chunks for a clean exit.

One writer per `./data-java` (`.jbitnode.lock` with pid metadata). Preflight reclaims stale locks
when the holder pid is dead. On `ValidationBlocker`, harvest via Core RPC, fix + regression, update
`docs/BLOCKER_LEDGER.md`, then resume with `make java-node-sync-chunk` or the supervisor.

`java-node-sync-chunk` defaults to `BLOCKS_MAX=5000` and `PAR_SCRIPT_VERIFY=1`.
For a single large unattended run (no auto-restart), use `make java-node-sync-chunk-overnight`
(default 15000; override with `BLOCKS_MAX=25000` etc.). Use `make java-node-sync-catchup
BLOCKS_MAX=0` only for rare unlimited debug runs.

`MAVEN_OPTS` defaults to `-Xmx4g -XX:+ExitOnOutOfMemoryError` on supervisor-launched sync.

### `java-node-sync-local-core` behavior

Connects to `PEERS` (default `127.0.0.1:48333`), runs version/verack/sendheaders
handshake, seeds genesis if needed, downloads headers in batches via
`getheaders`, then downloads blocks via `getdata`/`block` and connects
coinbase-only heights sequentially (stops honestly at the first block requiring
script verification).

Environment:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PEERS` | `127.0.0.1:48333` | Comma-separated host:port list |
| `DATA_DIR` | `./data-java` | Datadir for RocksDB stores and raw `blocks/` |
| `HEADERS_MAX` | `2000` | Max headers stored per run |
| `HEADER_BATCHES_MAX` | `50` | Max getheaders round-trips per run |
| `BLOCKS_MAX` | `64` (`sync-local-core`) / `5000` (`sync-chunk`) / `15000` (`sync-chunk-overnight`) / `0` (`sync-catchup`) | Max blocks per run |
| `SKIP_BLOCKS` | `false` | Set `true`/`1` for headers-only pass |
| `SYNC_TIMING` | `false` | Write per-stage timing rows to `events` (`source=timing`) |
| `PAR_SCRIPT_VERIFY` | `true` | Parallel script verify per transaction when input count ≥ min |
| `PAR_SCRIPT_THREADS` | CPU count | Max worker threads for parallel input verify |
| `PAR_SCRIPT_MIN_INPUTS` | `2` | Minimum inputs per tx before using parallel verify |

Historical catch-up example from the early P2TR key-path blocker era:

```bash
make java-node-sync-catchup
# equivalent explicit env:
HEADERS_MAX=10000 HEADER_BATCHES_MAX=50 BLOCKS_MAX=0 \
  PEERS=127.0.0.1:48333 DATA_DIR=./data-java make java-node-sync-local-core
```

`HeaderSync.EXTENDED_MAX_HEADERS` (`10000`) documents the recommended
`HEADERS_MAX` budget for one catch-up pass past height 7100 from ~500.

Each header is validated (prev hash, compact bits, PoW, chainwork) before
persistence. Each connected block is independently verified (prev link, block
hash, merkle root) before UTXO creation. Non-coinbase-only blocks stop connect
with an explicit blocker status — no script assumptions.

Example:

```bash
PEERS=127.0.0.1:48333 DATA_DIR=./data-java BLOCKS_MAX=16 make java-node-sync-local-core
make java-node-status
```

## Implemented modules (M2–M5)

| Package | Role |
|---------|------|
| `com.jbitnode.wire` | Message framing, compact-size, double-SHA256 checksum |
| `com.jbitnode.messages` | version/verack/sendheaders, getheaders/headers, inv/getdata/block |
| `com.jbitnode.p2p` | TCP peer connection, deferred handshake, block getdata |
| `com.jbitnode.sync` | Header download/validation; block download + coinbase-only connect |
| `com.jbitnode.consensus.connect` | Coinbase-only block connect, UTXO + validated tip updates |
| `com.jbitnode.consensus` | Target, chainwork, header validation |
| `com.jbitnode.consensus.tx` | Raw transaction parse/serialize (Milestone 7 prep) |
| `com.jbitnode.consensus.merkle` | Tx merkle root vs block header |
| `com.jbitnode.consensus.block` | Block payload deserialize (header + txs) |
| `com.jbitnode.consensus.script` | Opcode constants, stack machine scaffold (M9/M10 prep) |
| `com.jbitnode.cli.ExportSnapshotsService` | Retired snapshot-export stub |
| `com.jbitnode.cli.ScriptTemplateSurveyService` | Retired survey stub |
| `com.jbitnode.chain` | testnet4 params and genesis fixture |
| `com.jbitnode.db` | RocksDB operational and chainstate stores |

Harvested hex/block fixtures live under `src/test/resources/fixtures/` (see
`fixtures/README.md` for Python/TypeScript sources).

## Requirements

- Java 21 (OpenJDK)
- Maven 3.9+
- Docker / OrbStack (optional, for local Core)

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$PATH"
mvn test
```
