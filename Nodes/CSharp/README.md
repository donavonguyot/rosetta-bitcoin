# csbitnode — C# .NET 8 Bitcoin testnet4 follower

**csbitnode** is a managed-runtime follower in the Nodes workspace. Known
consensus rules come from the Shared rule ledger and script corpus; csbitnode
implements those rules independently and must reach tip with fully validated
connected blocks.

For code structure and design rationale, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For imported C# posture, use Project reports from the repository root:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
```

Query Project for current imported runway posture instead of treating README
proof notes as live status.

## Binary gate

From empty local state on Bitcoin testnet4, the node reaches and maintains tip while
independently validating every stored connected block. Partial sync, headers-only sync,
trusted import, or skipping unknown consensus rules does **not** pass.

## Follower discipline

| Source | Role |
|--------|------|
| [Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json](../Shared/consensus/rules/testnet4_script_rules_v1.json) | Primary known consensus rule inventory |
| [Nodes/Shared/conformance/fixtures/scripts/manifest.json](../Shared/conformance/fixtures/scripts/manifest.json) | Required 45-fixture script corpus |
| Java / Python / TypeScript | Proven implementation shapes and fixture provenance — not validity authority |
| Local Core `127.0.0.1:48333` | Byte source for headers/blocks — **not** a validation oracle |

## Datadir

| Item | Default |
|------|---------|
| Datadir | `./data-csharp/` (gitignored) |
| Chainstate | `./data-csharp/chainstate-rocksdb/` |
| Blocks | `./data-csharp/blocks/blk*.dat` |

**One writer per datadir.** Sync acquires `<DATA_DIR>/.csbitnode.lock`. A second sync
against the same datadir exits with `datadir lock busy`.

Never share datadirs or chainstate files with Python (`./data/chainstate-rocksdb`) or other followers.
CSharp's operational state is RocksDB.

## Deferred handshake

During initial sync, csbitnode sends only `version` → `verack` → `sendheaders`.
It does **not** send `feefilter`, `mempool`, or `sendcmpct` until headers are current.
`start_height` reflects validated height (honest), not header tip.

## Build and test

Requires .NET 8 (`brew install dotnet@8` on macOS).

```bash
cd Nodes/CSharp
make build
make test
make csharp-node-native-crypto-test
```

## Status

```bash
make node-status
# or
DATA_DIR=./data-csharp dotnet run --project src/CsBitNode/CsBitNode.csproj
```

Reports: runtime status, header/validated heights, stored block height, UTXO count,
active writer PID, chainstate backend, native crypto backend, current blocker, and
recommendation.

## Native crypto

Set `SECP256K1_BACKEND=native` to use the `Secp256k1.Net` libsecp256k1 wrapper for
ECDSA, Schnorr, and Taproot x-only tweak proof paths. Shared Shared vectors live at
`../Shared/conformance/fixtures/native_crypto_v1_vectors.json` and are exercised by
`make csharp-node-native-crypto-test`.

## Local Core sync

Primary development peer: **127.0.0.1:48333** (local Bitcoin Core testnet4).

```bash
make sync-local
# extended catch-up
HEADERS_MAX=10000 BLOCKS_MAX=512 make sync-local
# headers only
SKIP_BLOCKS=1 make sync-local   # set env SKIP_BLOCKS=1 in shell before sync-local
```

Equivalent:

```bash
DATA_DIR=./data-csharp PEERS=127.0.0.1:48333 \
  CSBITNODE_TOOL=sync dotnet run --project src/CsBitNode/CsBitNode.csproj -- sync
```

## Docker proofs

Docker proof targets use fresh named volumes for checkpoint artifacts. They are useful
for bounded gates and should stay separate from operational blocker hunting.

```bash
make docker-config
make docker-proof-local
make docker-proof-50k 2>&1 | python3 ../../Project/scripts/monitor_benchmark_telemetry.py
make docker-csharp-native-crypto-proof
# Larger bounded proof after smoke reporting is verified:
make docker-csharp-native-crypto-bounded-sync-proof
```

`make docker-proof-local` is the Project-comparable 5k lane: Docker runtime,
fresh proof volume, local Reference Core over P2P, block prefetch depth 4,
parallel script verification, WAL enabled, and compact evidence under
`../Shared/conformance/results/`. Official bounded benchmark proof targets emit
`benchmark.telemetry_tick` at a 10-second cadence so the shared 15-second
heartbeat validator has scheduling headroom. The
`docker-csharp-native-crypto-*` targets remain diagnostic/bounded proof
surfaces.

## Docker blocker hunting

Use the persistent supervisor for iterative live-chain work. It uses
`csbitnode_sync_data` by default and never deletes that volume during normal operation.
The supervisor runs sync in chunks, emits `AGENT_LOOP_TICK_chatreport` and
`benchmark.telemetry_tick` progress lines every 2 minutes,
pauses on blocker/error while continuing status ticks, then rebuilds and resumes from
the same volume after a code change or explicit resume marker. Chunk completion is
checked every few seconds by default, so 2-minute reporting does not throttle chunk
turnover.

```bash
make docker-csharp-sync-supervisor
make docker-csharp-sync-supervisor 2>&1 | python3 ../../Project/scripts/monitor_benchmark_telemetry.py
make docker-csharp-sync-status
make docker-csharp-sync-resume   # optional explicit resume trigger after a fix
make docker-csharp-sync-stop     # stop supervisor without deleting state
```

For a short local smoke of the supervisor loop:

```bash
DOCKER_SYNC_VOLUME=csbitnode_sync_smoke_data DOCKER_SYNC_BLOCKS_MAX=2 DOCKER_SYNC_POLL_SEC=10 \
  make docker-csharp-sync-supervisor
```

Only export a fresh proof artifact after a useful checkpoint or blocker is understood;
do not use fresh proof volumes as the normal blocker-hunting loop.

## Implementation surface

This README describes csbitnode commands and durable implementation shape, not
current gate posture. Query Project for imported status, benchmark gates, and
consensus runway state before making readiness or blocker claims.

Implemented surface:

- Wire framing and checksum verification
- Version/verack handshake with deferred post-verack messages
- Header sync from local Core with PoW/prev-link validation
- Block download via getdata/block
- Block/header parsing and merkle root validation
- Sequential block connection with coinbase UTXO creation
- Value-in/value-out accounting for non-coinbase paths (stops before script execution)
- Honest stop on unsupported script/consensus rules
- RocksDB chainstate + `make node-status`
- Native crypto proof fields and shared Shared vector execution
- Docker proof targets with 10-second benchmark telemetry headroom
- Persistent Docker supervisor with separate `POLL_SEC` report cadence and
  `CHECK_SEC` fast chunk-completion checks
- Serializable `ValidationBlockerRecord` DTO for blocker persistence

Script interpreter port follows Python blocker ledger entries (see `docs/BLOCKER_LEDGER.md`).

## Git

CSharp is root-owned under the single workspace Git repo. Live datadirs, build output, and DB files stay ignored.

```bash
git init   # if not already initialized
```

## Key paths

| Path | Purpose |
|------|---------|
| `src/CsBitNode/P2p/PeerConnection.cs` | Handshake, header/block requests |
| `src/CsBitNode/Sync/HeaderSync.cs` | Header download |
| `src/CsBitNode/Sync/BlockSync.cs` | Block download + connect loop |
| `src/CsBitNode/Consensus/Connect/BlockConnector.cs` | UTXO updates, validation stop |
| `src/CsBitNode/Cli/NodeStatusProgram.cs` | Status JSON |
| `docs/BLOCKER_LEDGER.md` | C# blocker handoff notes |
