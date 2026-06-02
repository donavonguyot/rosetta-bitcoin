# Python Native Replay Handoff

This handoff exists because the native-break plan stops at RocksDB/native-crypto
readiness. It does **not** claim full replay or rediscovered blockers.

## Current Native Surface

```text
state_path: ./data/chainstate-rocksdb
storage_backend: rocksdb
crypto_backend: coincurve
docker_proof: pybitnode-rocksdb-proof
docker_supervisor: pybitnode-supervisor
full_replay_status: pending
```

Legacy SQLite scout heights and snapshots are historical handoff evidence only.
They do not count as current Python native parity.

## Next Replay Plan Inputs

Use a fresh native datadir:

```bash
rm -rf ./data-python-native-replay
pybitnode-sync --datadir ./data-python-native-replay --peers 127.0.0.1:48333 --blocks-max <bounded chunk>
pybitnode-status --state-path ./data-python-native-replay/chainstate-rocksdb
```

Docker equivalent:

```bash
docker compose -f docker/docker-compose.yml up -d pybitnode-supervisor
docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-supervisor-status
```

Do not reuse `./data`, copied SQLite state, old snapshots, or any imported
chainstate as replay proof.

## Required Replay Facts

Every replay run should record:

```text
datadir
state_path
storage_backend
crypto_backend
peer
validated_height
header_height
stored_block_height
sync_status
current_blocker
advertised_start_height
stop_condition
proof_artifact
```

For a consensus blocker, add:

```text
height
block_hash
txid
input_index
spent_script_pubkey
failure
missing_rule
native_python_fix
test_fixture
follower_notes
```

## Stop Conditions

Stop and record facts when:

- A missing consensus rule blocks validation.
- P2P disconnect behavior suggests handshake/start-height drift.
- Native state reports a storage invariant failure.
- Docker supervisor emits `sync_status=error`.

Bounded storage proof is not full replay. Full replay evidence starts only when
the next plan syncs from an empty native datadir and records the resulting
blocker or tip-maintenance facts.
