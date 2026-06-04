# Storage Contract

Operational chainstate belongs to the port. `Project/project.db` is the tracked
mission-control SQLite database for exported observations and must never be
required for sync, validation, block lookup, UTXO lookup, blocker enforcement,
or status truth.

## Native Chainstate Rules

- Use `chainstate` for operational headers, block index, sync state, validated
  tip, UTXO set, undo records, metadata, blockers, and status truth.
- Use `status` for user-facing runtime inspection commands and
  `storage-proof` for bounded native storage proof commands.
- Use `legacy-sqlite` only for old port-local evidence, repair notes, and
  fail-closed guard tests. Active native paths should not be described as `db`,
  `SQLite`, `tracker`, or `ProjectTracker` in user-facing docs.
- The active backend reports `validated_height`, `validated_hash`, UTXO count,
  and chainstate status.
- RocksDB/native KV ports keep raw block bytes outside the chainstate backend,
  with an index that can locate stored blocks by height/hash.
- Native/Core mode must not create, read, or require SQLite for operational node
  truth: headers, block index, sync state, validated tip, UTXO set, undo records,
  chainstate metadata, blocker/current-error state, or status fields.
- Native storage proofs must not leave forbidden port-local SQLite runtime
  artifacts in the native datadir, and they must also fail hidden SQLite
  operational dependencies even when the SQLite file is outside the datadir.
- Port-local SQLite is allowed only behind an explicitly named legacy/reference
  mode. Project SQLite remains allowed and preferred for mission-control
  imports and reports after a node has exported observations.
- Each mutable datadir needs a single-writer guard. A second writer should fail
  before opening mutable state.
- Rebuild/replay tools must hold the same writer lock as sync.

## Current Evidence

- JavaNode has RocksDB/native-storage proof artifacts under
  `Nodes/Shared/conformance/results/`.
- CSharpNode has RocksDB codec/storage proof artifacts and a persistent Docker
  sync volume using native chainstate.
- TypeScript has a RocksDB `ChainstateStore` proof path and native status/proof
  commands. Legacy SQLite tracker surfaces are non-Core compatibility only.
- Python's old SQLite scout path is legacy evidence only. Python native-break
  work now targets RocksDB-owned operational truth, native crypto, and Docker
  proof/supervisor. Fresh blocker replay from empty native state remains a
  separate proof plan.
- Cpp's compliance path is RocksDB-only. Cpp is not compliant unless RocksDB
  owns all operational node truth without opening SQLite.
- Elixir has a RocksDB chainstate boundary and bounded proof path. Native
  secp256k1 and empty-datadir replay remain pending.

See `Nodes/Shared/storage/STORAGE_GATE.md` for the portable fixture contract.
