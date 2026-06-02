# CSharpNode Storage Gate Plan

`CSharpNode` is the first follower for the NodeCore storage gate. The goal is
not to broaden consensus scope; it is to make C# prove the same storage
invariants Java proved with its native storage path.

## Current Starting Point

Current C# runtime state is SQLite-centric:

```text
CSharpNode/data-csharp/
  csbitnode.db
  blocks/
  .csbitnode.lock
```

Important files:

```text
CSharpNode/src/CsBitNode/Db/Database.cs
CSharpNode/src/CsBitNode/Db/Schema.cs
CSharpNode/src/CsBitNode/Db/ProjectTracker.cs
CSharpNode/src/CsBitNode/Consensus/Connect/BlockConnector.cs
CSharpNode/src/CsBitNode/Storage/BlockStore.cs
CSharpNode/src/CsBitNode/Storage/DatadirLock.cs
CSharpNode/src/CsBitNode/Cli/SyncLocalCoreProgram.cs
CSharpNode/src/CsBitNode/Cli/NodeStatusProgram.cs
```

`ProjectTracker` currently owns operational truth. The storage gate requires
that truth to move behind a C# chainstate contract.

## Target Layout

```text
CSharpNode/data-csharp-native/
  chainstate/
  blocks/
  locks/
  .csbitnode_storage_native
```

The marker prevents legacy SQLite commands from accidentally opening a native
datadir.

## Implementation Steps

1. Define `IChainstateStore` under `CSharpNode/src/CsBitNode/Db/` with methods
   for validated tip, UTXO load/apply, undo read/write, block index records,
   metadata, stats, and atomic block commit.
2. Add `ChainstateMetadata` fields matching NodeCore: backend name, backend
   path, generation ID, schema version, status, tip height, and tip hash.
3. Introduce a native C# storage backend behind `IChainstateStore`. Start with
   a simple file-backed or embedded-key-value implementation only if it can pass
   the atomic commit and restart tests; otherwise pick a native KV backend after
   a small proof.
4. Refactor `BlockConnector` so validation builds the same block-local UTXO view
   but commits through `IChainstateStore`, not `ProjectTracker` SQLite tables.
5. Keep `BlockStore` for raw bytes and move the block index record into the
   active chainstate backend.
6. Add startup invariant checks before sync/status: marker mode, backend
   metadata, usable generation, tip alignment, block index coverage, and no
   stored block gaps below validated tip.
7. Add native-mode CLI/Makefile targets for fresh sync, status, project export,
   and storage-gate result generation. Legacy SQLite commands must fail on a
   marked native datadir.
8. Implement storage fixtures:
   `storage.native_fresh_start`, `storage.native_restart`,
   `storage.local_sqlite_artifact_absent`, and
   `storage.project_export_observational`.
9. Emit `NodeCore/conformance/results/csharp_storage_gate_<date>.json` using
   the shape in `NodeCore/storage/STORAGE_GATE.md`, then import it with
   `Project/scripts/import_conformance_results.py`.

## Non-Goals

- Do not use Java as a validity oracle.
- Do not require `Project/project.db` for sync, status, validation, block lookup,
  or restart.
- Do not preserve compatibility with unshipped C# SQLite internals unless it is
  needed for the explicit legacy promotion fixture.
- Do not start broad P2P or script-rule work as part of this storage gate slice.

## Pass Criteria

`CSharpNode` passes when:

```text
dotnet test passes
fresh native datadir sync connects block 1
restart connects block 2 from native state
no csbitnode.db appears in the native datadir
local SQLite artifact absence is passed
status reports chainstate_backend, generation_id, usable status, and validated tip
Project/project.db receives imported conformance rows only after runtime proof
```

After this passes, C# can begin broader NodeCore follower work with storage
truth aligned to the Java proof and NodeCore contract.
