# Storage Contract

Operational chainstate belongs to the port. `Project/project.db` is an
observational report database and must never be required for sync, validation,
block lookup, UTXO lookup, or status truth.

## Native Chainstate Rules

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
- SQLite is allowed only behind an explicitly named legacy/reference mode.
- Each mutable datadir needs a single-writer guard. A second writer should fail
  before opening mutable state.
- Rebuild/replay tools must hold the same writer lock as sync.

## Current Evidence

- JavaNode has RocksDB/native-storage proof artifacts under
  `NodeCore/conformance/results/`.
- CSharpNode has RocksDB codec/storage proof artifacts and a persistent Docker
  sync volume using native chainstate.
- TypeScript and Python currently remain SQLite-based by design and therefore
  are not making native/Core storage claims.
- Cpp's compliance path is RocksDB-only. Cpp is not compliant unless RocksDB
  owns all operational node truth without opening SQLite.

See `NodeCore/storage/STORAGE_GATE.md` for the portable fixture contract.
