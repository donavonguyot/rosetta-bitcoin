# Storage Gate

The storage gate is the portable proof that a port can own its operational
state in its intended native backend without depending on Project SQLite or
another implementation's live datadir. Project SQLite is mission-control state:
it may receive exported observations after a proof, but it must never drive
runtime sync, validation, block lookup, or status truth.

Java's native storage reference is the first passing example. Follower ports
must reproduce the same outcomes with their own code and local evidence.

## Required Invariants

Every port must prove:

```text
fresh_start:
  a clean datadir initializes native operational storage
  no forbidden port-local SQLite database is created

restart:
  a second run resumes from native operational storage only
  validated tip, headers, block index, and chainstate survive process exit

block_storage:
  raw block bytes are stored outside the active chainstate
  block index records can locate stored blocks by height/hash

project_boundary:
  Project/project.db receives exported observations only
  runtime sync, validation, block lookup, and status do not require Project/project.db

fail_closed:
  a marker identifies storage-mode-specific datadirs
  legacy or incompatible runtime entry points fail before opening the wrong store

single_writer:
  mutating runtime commands acquire the port's datadir lock
  overlapping writers must fail instead of sharing mutable state
```

## Native Means No Operational SQLite

For Core Node native mode, SQLite must not be part of operational node truth.
This is broader than checking whether `cpbitnode.db` or another `*.db` file is
left in the proof datadir.

Native/Core sync, status, proof, rebuild, and blocker-diagnostic commands must
not create, read, or require SQLite for:

```text
headers
block index
sync state
validated tip
UTXO set
undo records
chainstate metadata
blocker/current-error state
status snapshot fields
writer-lock truth
```

Port-local SQLite may exist only behind an explicitly named legacy/reference
mode. Native entry points must fail before opening SQLite-backed operational
state. Moving a SQLite observer outside the native datadir is not a valid
storage-gate proof if the native runtime still depends on that observer for
operational status or sync decisions. `Project/project.db` is the exception for
post-proof mission-control imports, not an exception to the runtime rule.

## Required Fixture IDs

The storage gate is expressed through these conformance fixture IDs:

```text
storage.native_fresh_start
storage.native_restart
storage.local_sqlite_artifact_absent
storage.project_export_observational
```

`storage.local_sqlite_artifact_absent` is a boundary check, not a complete
native-storage proof. It fails when a native storage proof leaves behind a
forbidden port-local SQLite runtime artifact in the native datadir. The broader
native invariant also fails if runtime code reaches SQLite-backed operational
state, even if the SQLite file lives outside the proof datadir.

## Evidence JSON

Each port should write one storage-gate result JSON under
`Nodes/Shared/conformance/results/` before importing it into `Project/project.db`.
The reusable proof shape is defined by
[`../conformance/storage_gate.schema.json`](../conformance/storage_gate.schema.json).

```json
{
  "implementation": "JavaNode",
  "commit": "",
  "node_id": "javanode-native-storage",
  "category": "storage",
  "captured_at": "",
  "datadir": "Nodes/Java/data-java-native-storage-smoke",
  "chain": "testnet4",
  "chainstate_backend": "rocksdb",
  "native_storage": true,
  "local_sqlite_artifact_absent": true,
  "validated_height": 2,
  "validated_hash": "",
  "header_height": 4000,
  "stored_block_height": 2,
  "chainstate_status": "usable",
  "project_export": {
    "project_db": "Project/project.db",
    "node_id": "javanode-native-storage",
    "result": "passed"
  },
  "results": [
    {
      "fixture_id": "storage.native_fresh_start",
      "result": "passed",
      "validated_height": 1,
      "validated_hash": "",
      "chainstate_backend": "rocksdb",
      "duration_ms": 0,
      "failure": ""
    }
  ],
  "commands": []
}
```

The top-level result summarizes the smoke proof. The `results` array is the
portable conformance surface imported into `Project.conformance_results`.

## Pass Criteria

A port passes the storage gate when:

```text
all required fixture IDs are passed or explicitly skipped where allowed
chainstate_status == usable
chainstate_backend is the port's intended native backend
validated_height >= 2 for the smoke restart proof
stored_block_height >= validated_height
local_sqlite_artifact_absent == true for native storage proofs
project_export.result == passed
Project/project.db is not read by runtime sync, status, block lookup, or validation
no SQLite-backed operational store is opened by native sync/status/proof paths
```

Passing Java does not pass any follower. Followers may copy fixture facts and
result shape, but each port must emit its own local evidence and status export.

## Java Reference Artifact

Current Java proof:

```text
Nodes/Shared/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json
Nodes/Shared/conformance/results/java_rocksdb_codec_v2_storage_shared_2026-06-01.json
Project/project.db node_id=javanode-native-storage
```
