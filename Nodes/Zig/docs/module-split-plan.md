# Module split

Base: `main` at `8bb670c`. Branch `zig/module-split`.

This is a move-only refactor. No behavior change, no new tests, no comments,
no edits inside `script.zig`, no other ports. Each extraction is one commit.
`zig build test` runs after every commit under `-Dstore=both`, `rocksdb`, and
`native`, with the same test count and the same one skip under native.

`root.zig` is 1,994 lines. `main.zig` is 1,548 lines. `rung0.zig` is replay
logic (`TraceInfo`, `replay`, boundaries) and stays at `src/rung0.zig`. The
CLI wrappers around it move under `cli/`.

## Where the lines go

From `src/root.zig` at `8bb670c`:

| Lines | Destination | Notes |
|---:|---|---|
| 30–91 | `types.zig` | `PortInfo` through `Metadata` |
| 93–101, 126–261, 859–896, 1544–1601 | `codec.zig` | encode/decode, hex, `CodecVectors`, `verifyCodecVectors`, and the private append helpers those functions call |
| 103–124, 1603–1628 | `datadir.zig` | `nowMs` (the libc clock `root.nowMs`), `rejectUnapprovedRuntimeDbArtifacts`, `DatadirLock`. `store.nowMs` stays in `store.zig` |
| 15, 1540–1542 | `crypto_glue.zig` | the `secp` selection: re-export `crypto` and `secp256k1Available` |
| 898–908, 955–1538 | `connect.zig` | timings, `connectDecodedBlock`, script runner, `foldSpends`, `isSpendableOutput`. `elapsedMs` and the unused `hexAlloc` move with this block so nothing is deleted |
| 263–857, 910–953 | `rocks_store.zig` | whole `RocksDb`, including the not-compiled stub and `rocks_meta`. Built only when `store_rocksdb` is set, same as today |
| 1630–1828 | `shadow_store.zig` | `ShadowStore` and `freeRaw` |
| 1830–1994 | the module that owns the assertion | tests move with the code they call; `root.zig` references them with `test { _ = @import(...) }` |

`root.zig` ends as re-exports only, under 60 lines. Existing
`@import("root.zig")` names keep working through those re-exports. Extracted
files import `types.zig`, `codec.zig`, and the other leaves. They do not
import `root.zig`, so the graph stays acyclic.

`src/main.zig` moves to `src/cli/main.zig` when the CLI split starts.
`build.zig` points the executable at that path. One commit per group, and
`cli/main.zig` shrinks each time:

1. `cli/common.zig` — `valueArg`, `flagArg`, JSON helpers, provenance stamp, `elapsedMs`
2. `cli/sync.zig` — `sync`, `local-reference-proof`, `sync-supervisor-once`
3. `cli/status.zig`
4. `cli/storage_proof.zig`
5. `cli/vectors.zig` — `codec-vectors`, `native-crypto-vectors`, `test-capability`
6. `cli/script_corpus.zig`
7. `cli/headers.zig` — `check-headers`
8. `cli/context.zig` — `consensus-context`, `write-context-fixtures`
9. `cli/mempool.zig` — `mempool-replay`
10. `cli/mining.zig` — `build-template`, `testblockvalidity`
11. `cli/bench.zig` — `crypto-bench`

Existing modules keep their file names. Imports are retargeted only when a
symbol moves. `script.zig` internals are not edited.

## Extraction guard

Last commit. Nothing under `Nodes/Zig` may name a path outside `Nodes/Zig`
except through `-Dfixtures-root` or `-Dshared-root` (defaults: the in-tree
locations) or the fixture package. Makefile targets take each root from one
variable. `build.zig` resolves them once and passes build options. Sources
and tests read the option.

`Nodes/Zig/scripts/check_no_external_paths.sh` greps for `../Shared`,
`../../`, and absolute `/Users/` under `Nodes/Zig` and fails on a hit. It is
a `zig build test` step. Acceptance: `zig build test
-Dfixtures-root=/some/copy/of/the/fixtures` passes with the tree's fixture
reads coming from that copy.

Doc comments that mention Shared stay until the documentation task. The
guard's path rule covers sources, tests, Makefile, and `build.zig`. Markdown
links under `docs/` are not runtime paths and are left for the doc pass if
the grep would only be satisfied by rewriting prose.

## Oracles

Gates after the types/codec commit, the connect commit, the rocks/shadow
commit, and the final guard commit:

- `make native-storage-proof`
- `make zig-node-storage-proof`
- `make native-shadow-5k` — set hash `e8a9c06f…d07400`, 4574 UTXOs
- `make self-hosted-50k` — set hash and count from the lane file
- `check-headers` on the tip store — 155070 heights, 76 retargets, 105573
  min-difficulty, 76 timewarp
- `make mempool-replay` — 30 accepted, 138 rejected, same boundary hashes

Indexed predecessors:

- `Nodes/Shared/conformance/results/zig_native_store_storage_proof_host_2026-10-03.json`
- `Nodes/Shared/conformance/results/zig_native_store_shadow_5k_host_2026-10-05.json`
- `Nodes/Shared/conformance/results/zig_self_hosted_50k_host_2026-10-04.json`
- `Nodes/Shared/conformance/results/zig_mempool_rung0_host_2026-10-04.json`

A gate JSON may differ from its predecessor only in `binary_sha256`,
`source_commit`, timestamps, and `ambient`. Any other field difference is a
bug. ReleaseSafe. Zig 0.16.0.

`crypto-bench` once at the end, quiet window: verify `ratio_min` within 3%
of the 1.931 baseline. `point_double` still has no field `bl`.

No source file over 1,000 lines except `script.zig`. `root.zig` under 60.

## Evidence

`Nodes/Shared/conformance/results/zig_module_split_<date>.json`, schema
`port.module_split.v1`, claim `refactor`. Per commit: files created, line
counts before and after, gate results and JSON diffs, the external-path
check, the final bench ratio. Import. Port status unchanged.

Merge `--no-ff` to `main` and push when the oracles pass.
