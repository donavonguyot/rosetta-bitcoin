# Storage Contract

Operational chainstate belongs to the port. `Project/project.db` is the tracked
mission-control database for exported observations and must never be
required for sync, validation, block lookup, UTXO lookup, blocker enforcement,
or status truth.

## Native Chainstate Rules

- Use `chainstate` for operational headers, block index, sync state, validated
  tip, UTXO set, undo records, metadata, blockers, and status truth.
- Use `status` for user-facing runtime inspection commands and
  `storage-proof` for bounded native storage proof commands.
- Active native paths should be described as RocksDB runtime storage.
- The active backend reports `validated_height`, `validated_hash`, UTXO count,
  and chainstate status.
- RocksDB/native KV ports keep raw block bytes outside the chainstate backend,
  with an index that can locate stored blocks by height/hash.
- Native/Core mode must create, read, and require RocksDB for runtime truth:
  headers, block index, sync state, validated tip, UTXO set, undo records,
  chainstate metadata, blocker/current-error state, and status fields.
- Native storage proofs must report `chainstate_backend=rocksdb`,
  `runtime_truth_backend=rocksdb`, and `rocksdb_runtime_truth=true`, with no
  dependency on `Project/project.db`.
- `Project/project.db` remains allowed and preferred for mission-control imports
  and reports after a node has exported observations.
- Each mutable datadir needs a single-writer guard. A second writer should fail
  before opening mutable state.
- Rebuild/replay tools must hold the same writer lock as sync.

## Evidence Lookup

Current storage evidence is indexed by Project:

```bash
python3 Project/scripts/report.py --db Project/project.db --section conformance
python3 Project/scripts/query_db.py \
  --sql "select port, category, result, result_count, max_validated_height from conformance_summary order by port, category, result"
```

See `Nodes/Shared/storage/STORAGE_GATE.md` for the portable fixture contract.
