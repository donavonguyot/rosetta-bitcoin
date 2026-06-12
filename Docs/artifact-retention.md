# Artifact Retention

This workspace keeps source, contracts, and compact evidence. It does not keep
live node state, generated build trees, local logs, or one-off proof scratch
unless they have been promoted to a canonical result.

## Artifact Classes

| Class | Owner | Keep where | Commit? | Notes |
|-------|-------|------------|---------|-------|
| Canonical project evidence | Root | `Nodes/Shared/conformance/results/` | Yes | Compact JSON proof that supports a project-level claim. |
| Current evidence index | Root | `Nodes/Shared/conformance/current_evidence.json` | Yes | Curated list of proof JSON files that support current Project status. |
| Shared schemas/manifests | Root | `Nodes/Shared/conformance/`, `Nodes/Shared/docker/` | Yes | Contracts, fixture IDs, Docker manifests, validators. |
| Port durable evidence | Root | `Nodes/<Port>/docs/`, `Nodes/<Port>/tests/fixtures/`, intentional `snapshots/` | Yes | Blocker facts, fixtures, and settled checkpoint exports. |
| Mission-control aggregate | Root | `Project/project.db` | Yes | Tracked Project index rebuilt from canonical JSON, manifests, status exports, ledgers, and decisions. |
| Runtime state | Port-local | `data*`, `blocks/`, RocksDB/LevelDB dirs, local DB files | No | Live truth for a port, never a root-owned artifact. |
| Generated build output | Port-local | `build*/`, `target/`, `dist/`, `_build/`, `deps/`, `node_modules/`, `.venv/` | No | Regenerate from source. |
| Legacy cruft | None | N/A | No | Stale logs, duplicate proof dirs, temp observer DBs, crash dumps, stale pid/lock files, nested `.git/` metadata. |

## Legacy Workspace Harvests

The retired archive workspace is external
archives. A harvest may add small Markdown summaries, checksum/manifests,
rewritten RosettaBitcoin-native contracts, or deliberately promoted compact proof JSON. It
must not import live DBs, nested `.git` directories, dependency trees, generated
build output, portal/book/audio bulk assets, old proof scratch, local blocks,
chainstate, logs, or runtime state.

Any harvested fact that supports a current project claim must be rewritten into
the current evidence system: canonical docs, Shared fixtures/contracts, port
durable evidence, or compact JSON under `Nodes/Shared/conformance/results/`
with explicit inclusion in `Nodes/Shared/conformance/current_evidence.json`.

## Canonical Result Naming

Canonical project evidence uses:

```text
Nodes/Shared/conformance/results/<port>_<gate>_<surface>_<YYYY-MM-DD>.json
```

Examples:

```text
Nodes/Shared/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json
Nodes/Shared/conformance/results/cpp_rocksdb_codec_v2_storage_2026-06-02.json
```

Result JSON should be small, machine-readable, and self-describing:

- implementation / node id
- chain and runtime surface
- RocksDB runtime backend
- validated/header/stored-block heights
- peer mode, when relevant
- command or fixture id
- pass/fail result and exact blocker facts when failed

Do not centralize live DBs, block files, full logs, Docker volumes, or RocksDB
directories. Export a compact proof JSON instead.

## Evidence Index

`Nodes/Shared/conformance/current_evidence.json` decides which committed proof
JSON files support current Project status. Normal Project refreshes import this
working set:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
```

Historical archaeology is explicit:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild --include-history
```

Use Project to inspect the current set and retained historical candidates:

```bash
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
python3 Project/scripts/report.py --db Project/project.db --section historical-evidence-candidates
```

## Port-Local Evidence

Keep port-specific durable evidence in root-owned port directories:

- `docs/BLOCKER_LEDGER.md`
- `docs/STATUS.md`
- `tests/fixtures/**`
- `snapshots/*.json` when that port intentionally uses committed snapshots

Snapshots are checkpoint evidence, not live truth. Live DB/status commands are
fresher while a port is actively syncing.

## Deletion Rules

Delete only after classification:

1. Preserve or regenerate compact proof JSON under `Nodes/Shared/conformance/results/`
   when the artifact supports a current project claim, and add it to
   `Nodes/Shared/conformance/current_evidence.json`.
2. Confirm no docs, manifests, or status tables cite the local artifact path.
3. Keep primary active datadirs unless explicitly approved for space reclamation.
4. Remove stale logs, duplicate scratch datadirs, temporary observer DBs, stale
   pid/lock markers, and generated build trees.

Primary datadirs such as `Nodes/Python/data`, `Nodes/TypeScript/data-ts`,
`Nodes/Java/data-java`, and `Nodes/Reference/bitcoin-core-testnet4` are runtime
state. They may be large, but they are not legacy cruft by default.

## Project Import Boundary

`Project/project.db` is the tracked mission-control database. Project scripts
may import canonical result JSON, Docker manifests, blocker ledgers, and
exported status JSON. Node runtimes and proof paths must not depend on
`Project/project.db` for sync, validation, chainstate, UTXO, block lookup,
blocker enforcement, or status truth.
