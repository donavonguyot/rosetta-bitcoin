# Artifact Retention

This workspace keeps source, contracts, and compact evidence. It does not keep
live node state, generated build trees, local logs, or one-off proof scratch
unless they have been promoted to a canonical result.

## Artifact Classes

| Class | Owner | Keep where | Commit? | Notes |
|-------|-------|------------|---------|-------|
| Canonical project evidence | Root | `NodeCore/conformance/results/` | Yes | Compact JSON proof that supports a project-level claim. |
| Shared schemas/manifests | Root | `NodeCore/conformance/`, `NodeCore/docker/` | Yes | Contracts, fixture IDs, Docker manifests, validators. |
| Port durable evidence | Port repo | `Nodes/<Port>/docs/`, `Nodes/<Port>/tests/fixtures/`, intentional `snapshots/` | Port-specific | Blocker facts, fixtures, and settled checkpoint exports. |
| Observational aggregate | Root | `Project/project.db`, `Project/reports/generated/` | No | Generated imports/reports. Rebuild from canonical JSON or status exports. |
| Runtime state | Port-local | `data*`, `blocks/`, RocksDB/LevelDB dirs, local DB files | No | Live truth for a port, never a root-owned artifact. |
| Generated build output | Port-local | `build*/`, `target/`, `dist/`, `_build/`, `deps/`, `node_modules/`, `.venv/` | No | Regenerate from source. |
| Legacy cruft | None | N/A | No | Stale logs, duplicate proof dirs, temp observer DBs, crash dumps, stale pid/lock files. |

## Canonical Result Naming

Canonical project evidence uses:

```text
NodeCore/conformance/results/<port>_<gate>_<surface>_<YYYY-MM-DD>.json
```

Examples:

```text
NodeCore/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json
NodeCore/conformance/results/cpp_rocksdb_codec_v2_storage_2026-06-02.json
```

Result JSON should be small, machine-readable, and self-describing:

- implementation / node id
- chain and runtime surface
- backend and storage boundary
- validated/header/stored-block heights
- peer mode, when relevant
- command or fixture id
- pass/fail result and exact blocker facts when failed

Do not centralize live DBs, block files, full logs, Docker volumes, or RocksDB
directories. Export a compact proof JSON instead.

## Port-Local Evidence

Keep port-specific durable evidence in the port repo:

- `docs/BLOCKER_LEDGER.md`
- `docs/STATUS.md`
- `tests/fixtures/**`
- `snapshots/*.json` when that port intentionally uses committed snapshots

Snapshots are checkpoint evidence, not live truth. Live DB/status commands are
fresher while a port is actively syncing.

## Deletion Rules

Delete only after classification:

1. Preserve or regenerate compact proof JSON under `NodeCore/conformance/results/`
   when the artifact supports a current project claim.
2. Confirm no docs, manifests, or status tables cite the local artifact path.
3. Keep primary active datadirs unless explicitly approved for space reclamation.
4. Remove stale logs, duplicate scratch datadirs, temporary observer DBs, stale
   pid/lock markers, and generated build trees.

Primary datadirs such as `Nodes/Python/data`, `Nodes/TypeScript/data-ts`,
`Nodes/Java/data-java`, and `Nodes/Reference/bitcoin-core-testnet4` are runtime
state. They may be large, but they are not legacy cruft by default.

## Project Import Boundary

`Project/project.db` is observational. Project scripts may import canonical
result JSON or exported status JSON, but node runtimes and proof paths must not
depend on `Project/project.db`.
