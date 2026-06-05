# rsbitnode

`rsbitnode` is the Rust follower port for the RosettaBitcoin workspace. The
current milestone is a Core-native scaffold plus bounded local-reference proof:
RocksDB-owned storage metadata, status JSON, storage proof output, Chainstate
Codec v2 vector checks, native crypto vector checks, Docker smoke/proof
surfaces, raw block/transaction parsing, and a Rust script-corpus harness for
the shared 45-fixture Shared corpus. Rust also exposes a narrow local Reference
P2P comparator for the 5k supporting gate.

This milestone does not claim live P2P sync, testnet4 tip maintenance, or
binary-gate progress. Host and Docker local-reference replay currently reach
height 10000 with `binary_gate_status=not_attempted`; the official comparable
5k lane uses local Reference P2P block acquisition.

## Commands

```bash
make build
make test
make rust-node-status
make rust-node-storage-proof
make rust-node-codec-vectors
make rust-node-native-crypto-vectors
make rust-node-script-corpus
make rust-node-sync-local
make rust-node-connect-local
make rust-node-local-reference-proof
make rust-node-local-reference-proof-fast
```

## Native/Core State

Native state lives under the selected datadir:

```text
<datadir>/
  .rsbitnode_native_storage
  chainstate-rocksdb/
```

Rust native proofs report RocksDB runtime truth. Status and storage proof read
Rust-owned RocksDB metadata directly.

## Local-Reference Proof Pipeline

`local-reference-proof --mode pipeline` fetches from local Reference Core,
decodes and validates each block in Rust, and connects the already-decoded block
directly in strict height order. Fetch and parse work is bounded-prefetched by
`RSBITNODE_BLOCK_PREFETCH_DEPTH` (default `4`, capped at `16`); UTXO mutation
and RocksDB commit remain single-threaded and ordered. Script verification runs
as deterministic parallel jobs by default; set
`RSBITNODE_SCRIPT_VERIFY_PARALLEL=0` to force sequential verification.

Progress output includes JSON telemetry with height, percent, elapsed time,
block rate, last-block time, fetched/connected counts, UTXO count, prefetch
depth, and script runner mode. Proof JSON includes `pipeline_timing_summary`
with wall time, byte fetch, parse/validate, store, connect, script, prevout,
commit, and UTXO timing fields. The top-level `blocks_fetched` and
`blocks_connected` fields are full proof counts; `connect_summary` is the final
block/connect snapshot.

`--byte-source p2p` speaks Bitcoin P2P to local Reference Core using
`getheaders`/`getdata`; `--byte-source rpc` keeps the historical Core RPC replay
lane. Both paths use the same Rust storage/connect pipeline.

The `*-fast` targets set `RSBITNODE_ROCKSDB_DISABLE_WAL=1` for disposable proof
runs only. Default runtime and proof commands keep RocksDB WAL enabled.

## Script Corpus

`rsbitnode script-corpus` loads all 45 entries from
`Nodes/Shared/conformance/fixtures/scripts/manifest.json` and runs a Rust-native
script verifier. Current coverage clears the shared `45/45` corpus without
delegating to another port or to Core validation.

## Docker

```bash
make docker-config
make docker-build
make docker-status
make docker-storage-proof
make docker-script-corpus
make docker-proof-local
make docker-probe-external
make docker-proof-rpc-replay
make docker-proof-local-fast
make docker-smoke-once
```

`docker-proof-local` is the official local Reference P2P 5k comparator and is
exposed to Project as `docker_proof_local`. `docker-proof-rpc-replay` preserves
the older Core RPC replay lane as evidence-only. `docker-proof-local-fast` keeps
its WAL-off diagnostic role and must not be benchmark-ranked.
`docker-probe-external` requires `DOCKER_EXTERNAL_P2P_PEER=<host:48333>` and
records diagnostic public testnet4 peer evidence only.
