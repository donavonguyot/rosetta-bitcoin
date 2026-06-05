# Storage Gate

The storage gate is the portable proof that a port owns runtime truth in
RocksDB. `Project/project.db` is mission-control state: it may receive exported
observations after a proof, but it must never drive runtime sync, validation,
block lookup, or status truth.

Java's native storage reference is the first passing example. Follower ports
must reproduce the same outcomes with their own code and local evidence.

## Required Invariants

Every port must prove:

```text
fresh_start:
  a clean datadir initializes RocksDB runtime storage

restart:
  a second run resumes from RocksDB
  validated tip, headers, block index, and chainstate survive process exit

block_storage:
  raw block bytes are stored outside the active chainstate
  block index records can locate stored blocks by height/hash

project_boundary:
  Project/project.db receives exported observations only
  runtime sync, validation, block lookup, and status do not require Project/project.db

fail_closed:
  a marker identifies storage-mode-specific datadirs
  incompatible runtime entry points fail before opening the wrong store

single_writer:
  mutating runtime commands acquire the port's datadir lock
  overlapping writers must fail instead of sharing mutable state
```

## RocksDB Runtime Truth

For official Core Node mode, RocksDB owns runtime node truth. The proof is not
an absence scan. It demonstrates that the runtime creates, reads, and resumes
from RocksDB for the state surfaces that matter.

Native/Core sync, status, proof, rebuild, and blocker-diagnostic commands must
create, read, and require RocksDB for:

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

`Project/project.db` is allowed only for post-proof mission-control imports, not
as a runtime dependency.

## Required Fixture IDs

The storage gate is expressed through these conformance fixture IDs:

```text
storage.native_fresh_start
storage.native_restart
storage.rocksdb_runtime_truth
storage.project_export_observational
```

Historical artifacts may contain older fixture names. Project imports those
names as aliases for `storage.rocksdb_runtime_truth`. New artifacts, templates,
docs, and tests must use the canonical fixture name.

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
  "runtime_truth_backend": "rocksdb",
  "rocksdb_runtime_truth": true,
  "native_storage": true,
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
chainstate_backend == rocksdb
runtime_truth_backend == rocksdb
rocksdb_runtime_truth == true
validated_height >= 2 for the smoke restart proof
stored_block_height >= validated_height
project_export.result == passed
Project/project.db is not read by runtime sync, status, block lookup, or validation
RocksDB is opened by native sync/status/proof paths
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
