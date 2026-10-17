# zigbitnode architecture

`src/cli/main.zig` dispatches commands. `src/root.zig` re-exports library modules;
it does not own their implementation. Build/export instructions are in the
[README](../README.md). Imported readiness belongs to RosettaBitcoin Project
reports, not this architecture map.

| Modules | Responsibility |
|---------|----------------|
| `types.zig`, `codec.zig` | Metadata and Chainstate Codec v2 key/value encodings. |
| `datadir.zig` | Datadir checks, clock, and single-writer datadir lock. |
| `p2p.zig` | Peer handshake and block/header fetch for bounded sync. |
| `chain_params.zig`, `consensus_context.zig` | Testnet4 difficulty, timewarp, finality, and sequence-lock context. |
| `block.zig`, `tx.zig` | Decode block/transaction bytes and enforce structural rules. |
| `connect.zig` | Parent-link checks, block-local UTXO view, spend verification, and connect orchestration. |
| `script.zig` | Script semantics and Bitcoin signature-hash construction. |
| `crypto.zig`, `crypto_glue.zig`, `own_crypto.zig` | Build-selected crypto adapters. |
| `rocks_store.zig`, `native_store.zig`, `store.zig` | Durable chainstate, commit, undo, and disconnect. |
| `shadow_store.zig` | Compare store outcomes while keeping each backend explicit. |
| `coins_view.zig`, `mempool.zig` | Overlay coins and transaction admission/eviction. |
| `template.zig`, `rung0.zig` | Template assembly and captured-trace replay. |
| `src/cli/` | Status, sync, vectors, corpus, storage, context, headers, reorg, mempool, mining, and benchmark wrappers. |

Connection uses the selected store's runtime truth, validates transactions before
committing chainstate, and stops on a validation blocker. Runtime validation
never opens Project's database. Stores record undo for disconnect. Mempool
restoration after disconnect remains a separate concern in the
[blocker ledger](blocker_ledger.jsonl).

Default builds use libsecp256k1 and compile both RocksDB and experimental native
storage. `own_curve` selects the local crypto package; `store=native` excludes
RocksDB. The package contains no node types. Adapters map errors and bytes;
script code owns Bitcoin-specific digest construction. `--build-info` reports
these selections so proof tooling can reject a mismatched binary.

The build owns fixture and proof-output roots. An exported tree includes its
crypto package and frozen fixtures. Tests write documentation coverage under
`zig-out/`; historical evidence lookup is optional via `-Ddoc-results-root`.
`rosetta.mk` owns optional lab topology and proof commands. Standalone builds
need none of those services or scripts.

Docker uses configurable build-context paths. Its test stage includes fixtures
and runs offline after dependency installation. The runtime stage contains the
binary and native runtime dependencies; state belongs in an explicit datadir
or Docker volume.

Generate API documentation with `zig build docs`. Style is defined in
[DOC_STANDARD.md](DOC_STANDARD.md). Cross-port consensus, storage, Docker, and
evidence contracts remain owned by RosettaBitcoin's `Nodes/Shared`.
