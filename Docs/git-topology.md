# Nodes Git Topology

The workspace root is a single root-owned monorepo. There is exactly one Git
repository:

```text
<workspace-root>/.git
```

Nested Git repositories under `Nodes/<Port>/` are legacy cruft and must not be
recreated.

## Root Repository

The root repository owns all source, contracts, docs, fixtures, manifests, and
selected conformance evidence:

- `AGENTS.md` and the root onboarding/read-order docs.
- `Docs/` for shared blocker, performance, supervisor, storage, crypto, and
  status lessons.
- `Nodes/Shared/` for language-neutral contracts, Docker runtime inventory, fixtures,
  and selected conformance proof artifacts.
- `Project/` for mission-control imports and reports. `Project/project.db` is
  tracked, queryable mission-control state, and must not become operational chainstate.
- `Nodes/` for all node implementation directories and the local Reference
  recipe.

The root repository does **not** own live node datadirs, build outputs, local
DBs, logs, dependency caches, Docker volumes, or nested `.git` metadata.
Artifact cleanup and proof retention rules live in
[`artifact-retention.md`](artifact-retention.md).

## Port Directories

These are normal tracked directories in the root repository:

- `Nodes/Python/` — Python port; forward parity target is full-break native/Core.
- `Nodes/TypeScript/` — fast follower.
- `Nodes/Java/` — lead follower / proof surface.
- `Nodes/Cpp/` — systems follower.
- `Nodes/CSharp/` — RocksDB/native-crypto follower.
- `Nodes/Go/` — Core-native scaffold follower.
- `Nodes/Rust/` — Core-native scaffold follower.
- `Nodes/Elixir/` — supervised follower.
- `Nodes/Reference/` — local Bitcoin Core testnet4 recipe.

Port directories keep their source, tests, fixtures, docs, package/build
manifests, Docker files, and intentional exported snapshots. They must ignore
live datadirs, local DBs, logs, dependency caches, and build output.

## Coordination Rule

Root docs can record cross-port facts, but each port must prove behavior with
its own implementation. A blocker row from another port is a handoff fact, not a
validity oracle.

## Checkpoint Rule

Use small root commits. Stage only intentional source, tests, docs, fixtures,
contracts, manifests, scripts, and selected compact proof artifacts.

Do not commit generated live state from any node directory.

Reusable, independently buildable crypto packages live under `Libraries/`. They
are root-owned source directories with package-local metadata and licenses, not
nested Git repositories. See `Libraries/README.md` and Project `crypto-lanes`.

## Zig extraction preparation

Zig remains root-owned until a separately authorized repository move. The
standalone export includes node source, its crypto dependency, fixture snapshots,
and the standalone workflow. The dependency update and future ownership boundary
are described in `Nodes/Zig/README.md`. No new repository is created by export.

The selective mempool integration takes watcher/activity tooling from
`zig/trace-watcher` through `59616eb`, ports its uncommitted replay diagnostics
into the split CLI, and takes only the selected-transaction witness from
`zig/mempool-stimulus` commit `f17dea2`. Historical captures are not promoted as
new proof. Capture-order replay, derived fixtures, and stimulus funding/broadcast
orchestration remain deferred.

Preserve `zig/trace-watcher` (`59616eb`) and `zig/mempool-stimulus` (`564a9c5`)
and their existing worktrees until the deferred work is explicitly resumed or
archived. Their uncommitted patches and untracked files were also copied to
`state:campaigns/zig-selective-integration-20261016/`, with a SHA-256 receipt.
The stimulus worktree includes the unfinished, untracked proof driver and
unrelated crypto evidence; neither belongs in this selective merge.

Before resuming stimulus, repair the preface JSON parsing, pre-block Core
sampling, non-vacuous RBF/CPFP checks, derived-directory discovery, and the
missing second replay on fresh state. No busy-trace, reorder, or tip-readiness
claim follows from the selected reporting changes.
