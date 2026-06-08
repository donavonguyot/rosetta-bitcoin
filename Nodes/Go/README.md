# gobitnode

`gobitnode` is a Go follower port for the RosettaBitcoin workspace. This README
describes command surfaces and implementation shape; Project reports own the
current imported gate posture.

For code structure and design rationale, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For imported Go posture, use Project reports from the repository root:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
```

The binary gate remains unchanged: from empty local state on Bitcoin testnet4,
the node must reach and maintain tip while independently validating every stored
connected block. Query Project for current imported runway posture instead of
treating README proof notes as live status.

## Commands

```bash
make build
make test
make go-node-storage-proof
make go-node-status DATA_DIR=./data-go-proof
make go-node-script-corpus
make go-node-sync-local DATA_DIR=./data-go-sync-10k SYNC_TARGET=10000
make go-node-connect-local DATA_DIR=./data-go-sync-10k CONNECT_TARGET=10000
```

## Native/Core State

Native state lives under the selected datadir:

```text
<datadir>/
  .gobitnode_native_storage
  chainstate-rocksdb/
  blocks/
```

Go native proofs report RocksDB runtime truth. Status and storage proof read the
Go chainstate directly.

## Local Reference Proofs

`gobitnode-sync` fetches raw blocks from the local Bitcoin Core RPC reference,
verifies block header hash, PoW target, previous-block linkage, and transaction
merkle root, then stores raw blocks plus block-index metadata in the Go RocksDB
datadir.

`gobitnode-connect` replays stored blocks from disk into the Go UTXO set with
native script verification. `gobitnode-local-reference-proof` uses the optimized
pipeline by default: it prefetches local Core RPC blocks, stores them, and
connects them in order with atomic RocksDB block commits, a block-local UTXO
view, batch prevout loads, binary UTXO codec v2, and timing evidence in the
result JSON. The staged fetch-then-connect mode remains available with
`--mode staged`.

`docker-proof-local` is the official 5k local Reference P2P comparator. It
speaks Bitcoin P2P to `REFERENCE_P2P_PEER` from `Nodes/Shared/docker/reference_topology.env` on the Reference Docker network, fetches headers and blocks
through `getheaders`/`getdata`, then uses the same Go storage/connect pipeline.
`docker-proof-rpc-replay` preserves the older local Reference RPC replay lane.

Docker P2P comparator artifacts are built by the Project control harness from
product progress. Query Project for the current accepted artifact, validated
height, comparability, and timing posture.

The historical Docker RPC replay proof started from a fresh Docker volume,
stored blocks through height 10000, and validated/connected through height 10000:

```text
result_path: Nodes/Shared/conformance/results/go_local_reference_docker_sync_2026-06-03.json
runtime_surface: docker
validated_height: 10000
validated_hash: 000000000037079ff4c37eed57d00eb9ddfde8737b559ffa4101b11e76c97466
sync_status: blocks_current
current_blocker: null
native_crypto_backend: libsecp256k1
```

Do not promote either bounded proof to the workspace binary gate: the 5k P2P
path is a comparator harness, and the 10k RPC replay path is evidence-only. Go
still needs persistent live P2P tip maintenance for binary-gate-adjacent work.

## Docker

```bash
make docker-config
make docker-build
make docker-status
make docker-storage-proof
make docker-script-corpus
make docker-proof-local
make docker-proof-rpc-replay
make docker-smoke-once
```

`docker-proof-local` uses a fresh named Docker volume, talks to host Core P2P at
`REFERENCE_P2P_PEER` from `Nodes/Shared/docker/reference_topology.env`, and writes compact official 5k evidence under
`Nodes/Shared/conformance/results/`. `docker-proof-rpc-replay` keeps the old
host Core RPC path at `host.docker.internal:48332` as explicit replay evidence.
Docker proof and supervisor volumes are separate from host datadirs.
