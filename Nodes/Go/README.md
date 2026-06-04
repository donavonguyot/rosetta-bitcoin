# gobitnode

`gobitnode` is a Go follower port for the RosettaBitcoin workspace. The current
milestone is an offline/Core-native proof surface: status, storage proof,
native crypto reporting, Docker smoke surfaces, native Shared script corpus,
and local-reference stored-block replay.

The binary gate remains unchanged: from empty local state on Bitcoin testnet4,
the node must reach and maintain tip while independently validating every stored
connected block. This Go milestone does not claim live P2P sync, tip
maintenance, or binary-gate completion.

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

No SQLite artifact is allowed in the Go native datadir. Status and storage proof
read the Go chainstate directly.

## Local Reference Sync Probe

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

The current Docker local-reference proof starts from a fresh Docker volume,
stores blocks through height 10000, and validates/connects through height 10000:

```text
result_path: Nodes/Shared/conformance/results/go_local_reference_docker_sync_2026-06-03.json
runtime_surface: docker
validated_height: 10000
validated_hash: 000000000037079ff4c37eed57d00eb9ddfde8737b559ffa4101b11e76c97466
sync_status: blocks_current
current_blocker: null
native_crypto_backend: libsecp256k1
```

Do not promote this to the workspace binary gate: it is a bounded local
reference RPC proof, not live P2P sync to current testnet4 tip.

## Docker

```bash
make docker-config
make docker-build
make docker-status
make docker-storage-proof
make docker-script-corpus
make docker-proof-local
make docker-smoke-once
```

`docker-proof-local` mirrors Java's bounded local-reference Docker proof shape:
it uses a fresh named Docker volume, talks to host Core RPC at
`host.docker.internal:48332`, runs the pipelined proof path by default, then
writes compact evidence under `Nodes/Shared/conformance/results/`. Docker proof and
supervisor volumes are separate from host datadirs.
