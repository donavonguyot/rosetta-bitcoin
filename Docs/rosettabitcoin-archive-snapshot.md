# RosettaBitcoin Archive Snapshot

Snapshot time: `2026-06-06T20:42:56Z`

Archive root: `/Users/donavonguyot/RosettaBitcoin`

Cleaned size: `753M`

Backup status: compressed backup taken before this snapshot.

This snapshot records the cleaned retired workspace for archaeology and
verification. It is not current RB evidence. Nothing in this snapshot supports
benchmark, consensus, Docker, storage, or full-node claims unless it is later
rewritten into RB-native docs, Shared contracts, fixtures, or compact proof JSON.

## Top-Level Inventory

| Surface | Size | Classification |
|---------|------|----------------|
| `rosetta-bitcoin-audio` | `492M` | Retained narrative/audio archive; bulk remains external to RB. |
| `rosetta-bitcoin` | `167M` | Historical proof-machine and custody archive. |
| `rosetta-java-node` | `68M` | Historical Java product-pressure snapshot with generated reports mostly pruned. |
| `rosetta-bitcoin-portal` | `20M` | Retained portal/story shell without dependency tree or Next cache. |
| `rosetta-bitcoin-book` | `3.0M` | Retained book/source-apparatus archive. |
| `roadmap.db` | `736K` | Retired coordination DB; not RB mission control. |
| `AGENTS.md` | `32K` | Retired root operating manual and decision summary. |

## Nested Repositories

Nested Git histories remain in the archive only. They must not be recreated
inside RB.

| Path | HEAD | Snapshot status |
|------|------|-----------------|
| `.` | `0f79c0d` | Clean in the sampled status output. |
| `rosetta-bitcoin` | `54026e2` | Dirty docs/untracked doc additions retained as archive state. |
| `rosetta-bitcoin-audio` | `7b2dfef` | Clean in the sampled status output. |
| `rosetta-bitcoin-book` | `2daf5a4` | Clean in the sampled status output. |
| `rosetta-bitcoin-portal` | `96c45c1` | Dirty story/site edits retained as archive state. |
| `rosetta-java-node` | `493501a` | Dirty Java product-track edits/untracked files retained as archive state. |

## Retained Large Artifacts

| Path | Size | Notes |
|------|------|-------|
| `rosetta-bitcoin-audio/artifacts/finaldraft-audio/exports/ThePromptEngineer.mp3` | `103M` | Retained audio output, external to RB. |
| `rosetta-bitcoin/state/canonical.sqlite3` | `89M` | Historical SQLite state, not current RB Project or runtime state. |
| `rosetta-java-node/reports/java-node/testnet-blocks.json` | `37M` | Retained generated report in the old archive, excluded from RB checksums. |
| `rosetta-bitcoin-book/ThePromptEngineer.pdf` | `280K` | Retained book output. |
| `roadmap.db` | `684K` | Retired roadmap/control-room DB. |

The root `roadmap.db-wal` is empty and `roadmap.db-shm` is transient. WAL/SHM
files are intentionally excluded from the checksum manifest.

## Checksum Manifest

RB records checksums in:

```text
Docs/rosettabitcoin-archive-checksums.sha256
```

The manifest has `3,482` relative-path entries from the old archive root. It
excludes `.git`, dependency trees, build/cache directories, Python virtualenv
and cache directories, old report/runtime directories, WAL/SHM files, logs, and
temporary files. It includes retained source/docs, archive material, manifests,
audio files, `roadmap.db`, and `rosetta-bitcoin/state/canonical.sqlite3`.

Verify from the archive root:

```bash
cd /Users/donavonguyot/RosettaBitcoin
shasum -a 256 -c /Users/donavonguyot/RB/Docs/rosettabitcoin-archive-checksums.sha256
```

## Restore And Use Rules

- Inspect the archive externally. Do not copy it wholesale into RB.
- Promote only rewritten RB-native summaries, contracts, fixtures, or compact
  proof artifacts.
- Treat IL as hypothesis/provenance only.
- Treat old proof ladders, generated reports, portal/book/audio assets, nested
  repositories, and historical runtime state as archive material.
- If future work needs a retained large artifact, cite its checksum and archive
  path rather than importing the bytes into RB.
