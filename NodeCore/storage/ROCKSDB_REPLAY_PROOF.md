# RocksDB Replay Proof

RocksDB replay proof is the operational evidence layer above Codec v2 vector
tests. A port passes this gate only when it replays real block fixtures through
its normal block storage, connect, and chainstate commit paths.

## Required Fields

Proof JSON files under `NodeCore/conformance/results` must include:

```text
chainstate_backend
chainstate_backend_version
operational_backend
operational_backend_path
codec_version
replay_target_height
blocks_connected
db_size_bytes
validated_height
validated_hash
stored_block_height
startup_invariant_ms
commit_latency_ms_total
commit_latency_ms_avg
commit_latency_ms_p50
commit_latency_ms_p95
commit_latency_ms_max
utxo_load_ms_p50
utxo_apply_ms_p50
block_store_ms_p50
block_connect_store_commit_ms_p50
block_connect_store_commit_ms_p95
block_connect_store_commit_ms_max
utxo_lookup_ms_total
utxo_lookup_ms_avg
fixture_replay_status
live_smoke_status
native_crypto_backend
native_crypto_available
taproot_tweak_backend
replay_corpus_id
replay_corpus_source
```

## Gate Order

```text
codec_v2_vectors
  -> fixture_replay
  -> restart_invariant_check
  -> proof_json_validation
  -> live_smoke_optional
```

Fixture replay must not use synthetic block hashes or direct UTXO insertion as
the proof mechanism. Synthetic storage writes are useful unit tests, but they do
not prove the block connect path.

## Replay Targets

Replay targets are staged so local checks stay fast while performance evidence
can grow as fixture or stored block ranges become available:

| Target | Purpose |
|--------|---------|
| `2` | Fast correctness smoke for CI and local iteration |
| `100` | First meaningful storage-path timing sample |
| `1000` | Medium replay range for p50/p95 stability |
| `5000` | Serious pre-live storage evidence |

Replay commands should connect the smaller of `BLOCKS_MAX` and the available
contiguous input range. Proofs must report both `replay_target_height` and
`blocks_connected` so missing input is visible.

## Shared Replay Corpus

A shared replay corpus is a generated local artifact, not a source-controlled
fixture dump. The portable format is:

```text
corpus_dir/
  replay_manifest.json
  blocks/
    block1_wire.hex
    block2_wire.hex
    ...
```

`replay_manifest.json` must include:

```text
corpus_id
chain
start_height
end_height
source
created_at
blocks[]:
  height
  block_hash
  file
```

The block files contain raw Bitcoin block payloads as hex, without network magic
or length prefix. Replay runners must validate that:

- heights are contiguous from `start_height`;
- each manifest block file exists;
- the decoded block hash matches `block_hash`;
- proof fields include `replay_corpus_id` and `replay_corpus_source`.

Ports may also replay from a native copied datadir when they understand that
datadir's block index. Corpus export is the preferred cross-port path.

## Metric Notes

- `db_size_bytes` is the recursive size of the RocksDB directory after replay.
- `commit_latency_ms_*` measures the block connect/store commit path.
- `*_p50`, `*_p95`, and `*_max` are computed over per-block timings for the
  replayed range.
- `utxo_lookup_ms_*` measures at least one lookup against a UTXO created by the
  replayed fixtures.
- `startup_invariant_ms` measures close/reopen and invariant verification.
- `live_smoke_status` must remain `not_run` unless a real peer/live run was
  attempted.
- `native_crypto_backend` reports the selected runtime crypto backend. Java
  native proofs report `libsecp256k1-acinq`.
- `native_crypto_available` must be `true` when `native_crypto_backend` claims a
  native backend.
- `taproot_tweak_backend` reports the implementation used for Taproot x-only
  tweak derivation; it must not imply native coverage if a port falls back to a
  pure implementation for that primitive.

## Strict Failure Rules

Proof validation must fail closed when:

- `chainstate_backend != "rocksdb"`.
- `operational_backend != "rocksdb"` for ports that have node-local operational KV state.
- `codec_version != "2"`.
- `fixture_replay_status != "passed"`.
- `db_size_bytes <= 0`.
- `blocks_connected < min(replay_target_height, available_input_height)`.
- `live_smoke_status == "passed"` without a separate live-peer proof.
