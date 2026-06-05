# Storage Gate

The storage gate is the portable proof that a port can own its operational
state in its intended native backend without depending on Project DB or another
implementation's live datadir. `Project/project.db` is mission-control state:
it may receive exported observations after a proof, but it must never drive
runtime sync, validation, block lookup, or status truth.

Java's native storage reference is the first passing example. Follower ports
must reproduce the same outcomes with their own code and local evidence.

## Required Invariants

Every port must prove:

```text
fresh_start:
  a clean datadir initializes native operational storage
  no port-local operational DB artifact is created outside the approved backend

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

## Native Operational Storage Boundary

For Core Node native mode, RocksDB/native storage owns operational node truth.
The boundary proof is broader than checking whether a stray `*.db` file is left
in the proof datadir.

Native/Core sync, status, proof, rebuild, and blocker-diagnostic commands must
create, read, and require only the approved native backend for:

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

Any compatibility or reference store must be explicitly named and excluded from
baseline proof paths. Native entry points must fail before opening the wrong
operational backend. Moving an observer outside the native datadir is not a
valid storage-gate proof if the native runtime still depends on that observer
for operational status or sync decisions. `Project/project.db` is allowed only
for post-proof mission-control imports, not as a runtime dependency.

## Required Fixture IDs

The storage gate is expressed through these conformance fixture IDs:

```text
storage.native_fresh_start
storage.native_restart
storage.operational_db_boundary
storage.project_export_observational
```

`storage.operational_db_boundary` is a boundary check, not a complete
native-storage proof. It fails when a native storage proof leaves behind a
port-local operational DB artifact outside the approved backend. The broader
native invariant also fails if runtime code reaches any unapproved operational
store, even if that store lives outside the proof datadir.

Historical artifacts may contain older fixture names for the same boundary.
Project imports those names as aliases for `storage.operational_db_boundary`.
New artifacts, templates, docs, and tests must use the canonical fixture name.

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
  "operational_db_artifact_absent": true,
  "runtime_db_boundary_passed": true,
  "project_db_observational_only": true,
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
operational_db_artifact_absent == true for native storage proofs
runtime_db_boundary_passed == true
project_db_observational_only == true
project_export.result == passed
Project/project.db is not read by runtime sync, status, block lookup, or validation
only the approved native backend is opened by native sync/status/proof paths
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
