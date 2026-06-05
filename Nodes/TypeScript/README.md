# tsbitnode

Binary-compatible Bitcoin full node in **TypeScript** for **testnet4**.

TypeScript is now a **Native/Core migration target**. Core/native mode may use
runtime npm dependencies only for RocksDB and `libsecp256k1` infrastructure
bindings; external Bitcoin libraries remain forbidden.

## Current Status

Native/Core parity requires RocksDB-owned operational truth, native crypto proof,
Docker proof/supervisor support, and fresh replay from an empty native datadir.
The historical SQLite tracker is legacy handoff evidence only and must not be
used for Core claims.

| Surface | Canonical command | Notes |
|---------|-------------------|-------|
| Native status | `npx tsbitnode-status --datadir ./data-ts` | Reads RocksDB chainstate without acquiring the writer lock. |
| Native storage proof | `npx tsbitnode-storage-proof --datadir ./data-ts-proof` | Bounded RocksDB/native crypto proof. |
| Sync runner | `npx tsbitnode-sync --datadir ./data-ts` | Uses the active sync lock for mutable state. |
| Legacy SQLite status | `npx tsbitnode-legacy-db --db ./data-ts/tsbitnode.db` | Legacy evidence/repair only; not a native/Core proof. |

## Native Chainstate

Native operational state lives under the selected datadir:

```text
<data-dir>/
  .tsbitnode_native_storage
  chainstate-rocksdb/
  blocks/
```

`ChainstateSession` rejects a native datadir that already contains
`tsbitnode.db`. This fail-closed guard prevents accidentally treating old
SQLite state as native operational truth.

Canonical native modules are under `src/chainstate/`:

| Path | Purpose |
|------|---------|
| `src/chainstate/chainstate.ts` | Chainstate interfaces and record types. |
| `src/chainstate/chainstateSession.ts` | Datadir/session boundary, lock handling, SQLite-artifact rejection. |
| `src/chainstate/rocksDbChainstateStore.ts` | RocksDB-backed chainstate implementation. |
| `src/storage/chainstateCodecV2.ts` | Shared codec for native chainstate keys/values. |

`src/db/` remains a legacy SQLite compatibility namespace for old tracker-based
snapshots, surveys, and repair notes. Do not add new native/Core code there.

## Build And Test

```bash
npm install
npm run build
npm test
```

Focused native checks:

```bash
npm run build
npx tsbitnode-storage-proof --datadir ./data-ts-proof
npx tsbitnode-status --datadir ./data-ts-proof
```

## Sync Operations

Typical staged sync:

```bash
npm run build
DATA_DIR=./data-ts npx tsbitnode-sync \
  --datadir ./data-ts \
  --blocks-target 10000 \
  --blocks-max 200 \
  --peers HOST:PORT
```

Block-only pass after headers are current:

```bash
npx tsbitnode-sync --datadir ./data-ts --no-header-refresh --blocks-max 64
```

Native status after a run:

```bash
npx tsbitnode-status --datadir ./data-ts
```

Key fields are `validated_height`, `header_height`, `stored_block_height`,
`sync_status`, `chainstate_backend`, `codec_version`, and
`local_sqlite_artifact_absent`.

## Single Writer Rule

One mutable writer per datadir. `tsbitnode-sync`, long-running `tsbitnode`,
rebuild tools, and native `ChainstateSession` writers must respect
`<datadir>/.tsbitnode_sync.lock`.

Before starting sync, confirm no conflicting process:

```bash
ps aux | rg 'syncBatchLoop|syncRunner|tsbitnode-sync|dist/cli/node'
ls -la Nodes/TypeScript/data-ts/.tsbitnode_sync.lock 2>/dev/null
```

## Docker

Docker targets are exposed through the Makefile:

```bash
make docker-config
make docker-build
make docker-typescript-native-proof
make docker-typescript-sync-status
make docker-typescript-sync-supervisor
make docker-typescript-sync-stop
make docker-typescript-sync-resume
make docker-smoke-once
```

The Docker manifest is `Nodes/Shared/docker/ports/typescript.docker.json`. Keep it
in sync whenever command names, volumes, or proof artifacts change.

## Legacy SQLite Evidence

SQLite-era artifacts remain useful only as historical handoff or repair evidence:

- `tsbitnode.db` snapshots around `validated_height=5578`.
- The 5579 dual-writer repair lesson.
- Legacy survey/export tools that still read the old tracker.

Use `tsbitnode-legacy-db` only when intentionally inspecting that evidence. New
native/Core work must use `tsbitnode-status`, `ChainstateSession`, and RocksDB
chainstate.

## Binary Gate

The end gate is unchanged: from empty local state on Bitcoin testnet4, the node
reaches and maintains tip while independently validating every stored connected
block. Current native TypeScript work is proof-partial until imported Project
evidence proves the relevant corpus, stage, and tip runway checks.
