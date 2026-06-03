# Conformance Manifest

Each fixture should include a manifest entry so every port runs the same test
with the same expected outcome.

## Fixture Entry

```text
fixture_id:
category:
chain:
height:
block_hash:
input_files:
expected_result:
expected_validated_height:
expected_validated_hash:
expected_status:
expected_blocker:
notes:
```

## Initial Fixture Set

```text
genesis.testnet4
headers.pow_valid
headers.bad_prev_hash
blocks.block1_connect
blocks.block2_connect
chainstate.same_block_spend
chainstate.atomic_commit_failure
chainstate.rebuild_promote
status.empty_node
status.blocks_current
status.blocks_blocked
live.current_tip
live.new_header_catchup
live.peer_disconnect
live.consensus_blocker
storage.native_fresh_start
storage.native_restart
storage.local_sqlite_artifact_absent
storage.rocksdb_operational_state_boundary
storage.project_export_observational
sync.deferred_handshake
sync.honest_start_height
sync.single_writer_guard
scripts.p2wpkh_739
scripts.p2tr_key_path_6975
scripts.p2tr_script_path_22830
```

## Script Corpus Fixtures

The Java-cleared script corpus is the bulk import of real testnet4 spend-path
fixtures that Java has already cleared. The corpus lives under
[`fixtures/scripts/`](fixtures/scripts/) and is indexed by
[`fixtures/scripts/manifest.json`](fixtures/scripts/manifest.json).

Script fixture IDs are stable cross-port contracts with this form:

```text
scripts.<template_or_family>_<rule_or_shape>_<height>
```

Each entry records the source Java metadata, copied fixture files, provenance,
expected result, required rule tags, and a `portability_status`.

```text
raw_imported     copied from Java and indexed, no cross-port loader guarantee
normalized       manifest shape and required files are structurally complete
loader_verified  at least one non-Java fixture loader can read it
cross_port_ready ready for follower implementation batches
absorbed         implemented and tested by a target follower port
```

Java may be the first port to prove these fixtures on live chain, but follower
ports pass only when they independently load the NodeCore fixture ID and record
their own result.

## Cross-Port Fixture Naming

Fixture IDs are the portable contract. A port may store fixture bytes in a
language-local test tree while this manifest is being bootstrapped, but the
fixture ID, chain, height, expected status, and blocker facts must match this
manifest.

Java may discover or clear a fixture first, but follower ports pass only when
their own implementation records a `passed` result for the same fixture ID.

## Storage Gate Fixtures

The canonical storage gate is defined in
[`../storage/STORAGE_GATE.md`](../storage/STORAGE_GATE.md). These entries are
required for storage readiness:

```text
fixture_id: storage.native_fresh_start
category: storage
chain: testnet4
height: 1
block_hash: port-local block 1 hash
input_files: language-local block 1 fixture or live testnet4 peer bytes
expected_result: passed
expected_validated_height: 1
expected_validated_hash: port-local block 1 hash
expected_status: usable native chainstate
expected_blocker:
notes: Fresh native-only datadir initializes operational metadata, headers, block index, chainstate, and marker/fail-closed state.

fixture_id: storage.native_restart
category: storage
chain: testnet4
height: 2
block_hash: port-local block 2 hash
input_files: existing native datadir from storage.native_fresh_start
expected_result: passed
expected_validated_height: 2
expected_validated_hash: port-local block 2 hash
expected_status: usable native chainstate
expected_blocker:
notes: Second run resumes from native operational storage and advances without Project DB or legacy local SQLite.

fixture_id: storage.local_sqlite_artifact_absent
category: storage
chain: testnet4
height:
block_hash:
input_files: native storage proof datadir
expected_result: passed
expected_validated_height:
expected_validated_hash:
expected_status: no forbidden port-local SQLite runtime artifact in native datadir
expected_blocker:
notes: Boundary check only; this does not preserve or require legacy migration behavior.

fixture_id: storage.project_export_observational
category: storage
chain: testnet4
height: latest storage smoke validated height
block_hash: latest storage smoke validated hash
input_files: storage gate result JSON and status JSON
expected_result: passed
expected_validated_height: latest storage smoke validated height
expected_validated_hash: latest storage smoke validated hash
expected_status: Project/project.db updated without becoming a runtime dependency
expected_blocker:
notes: Import/export may open Project/project.db only after runtime proof is complete.

fixture_id: storage.rocksdb_operational_state_boundary
category: storage
chain: testnet4
height: latest storage smoke validated height
block_hash: latest storage smoke validated hash
input_files: native storage proof datadir
expected_result: passed
expected_validated_height: latest storage smoke validated height
expected_validated_hash: latest storage smoke validated hash
expected_status: RocksDB owns operational metadata, headers, block index, sync state, tip, UTXO, undo, event, peer, and wire state
expected_blocker:
notes: Required for Cpp RocksDB-only compliance and useful for any future RocksDB-native port; no hidden SQLite observer is allowed.
```

## Result JSON

```json
{
  "implementation": "JavaNode",
  "commit": "",
  "fixture_id": "blocks.block1_connect",
  "result": "passed",
  "validated_height": 1,
  "validated_hash": "",
  "chainstate_backend": "rocksdb",
  "duration_ms": 0,
  "failure": ""
}
```

Storage gate result files use the aggregate shape documented in
[`../storage/STORAGE_GATE.md`](../storage/STORAGE_GATE.md) and the schema in
[`storage_gate.schema.json`](storage_gate.schema.json); Project imports each
entry in the aggregate `results` array as a `conformance_results` row.

## Import To Project DB

Conformance results are imported into `Project.project_db.conformance_results`
with the original JSON preserved in `raw_json`.
