# Checkpoint Strategy

Use these checkpoints in order. The workspace is a single root repository, so
commit boundaries are logical, not separate Git repos.

## Root Repo

1. Root hygiene and topology:
   - `.gitignore`
   - `README.md`
   - `AGENTS.md`
   - `docs/git-topology.md`
   - `docs/port-status.md`
2. NodeCore and Project promotion:
   - `NodeCore/`
   - `Project/`
   - proof artifact naming/reference fixes
   - Project status importer changes
3. Shared lessons and contracts:
   - `docs/blocker-ledger.md`
   - `docs/storage-contract.md`
   - `docs/native-crypto-contract.md`
   - `docs/supervisor-contract.md`
   - `docs/port-performance-lessons.md`
   - `docs/script-semantics-gotchas.md`
   - `NodeCore/diagnostics/BLOCKER_DIAGNOSTICS.md`

## Port Implementation Checkpoints

Commit port implementation/proof work separately from broad doc cleanup when
possible. Do not include live `.docker-*` status files, datadirs, local DBs,
target/build output, dependency caches, or transient logs.

Recommended Java cleanup checkpoint:

```text
Refresh Java RocksDB/native-crypto proof docs
```

Recommended C# cleanup checkpoint:

```text
Document C# supervisor frontier and 22830 blocker
```

## Commit Safety

Before each checkpoint:

1. Run `git status --short` at the workspace root.
2. Review `git diff --stat` and the relevant diffs.
3. Stage only intentional source, tests, docs, fixtures, contracts, and selected
   proof artifacts.
4. Keep generated state and live operational data ignored.
