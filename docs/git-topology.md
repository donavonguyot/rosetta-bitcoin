# Nodes Git Topology

`~/RB` is a single root-owned monorepo. There is exactly one Git repository:

```text
/Users/donavonguyot/RB/.git
```

Nested Git repositories under `Nodes/<Port>/` are legacy cruft and must not be
recreated.

## Root Repository

The root repository owns all source, contracts, docs, fixtures, manifests, and
selected conformance evidence:

- `AGENTS.md` and the root onboarding/read-order docs.
- `docs/` for shared blocker, performance, supervisor, storage, crypto, and
  status lessons.
- `NodeCore/` for language-neutral contracts, Docker runtime inventory, fixtures,
  and selected conformance proof artifacts.
- `Project/` for observational imports and reports. `Project/project.db` is
  generated and must not become operational chainstate.
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
