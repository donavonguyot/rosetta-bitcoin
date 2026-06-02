# Nodes Git Topology

`~/RB` uses the root repository as the coordination and contract layer, plus one
implementation repository per serious node under `Nodes/`. This is the current
policy until the workspace deliberately migrates to a monorepo or formal
submodules.

## Root Repository

The root repository owns shared infrastructure and cross-port truth:

- `AGENTS.md` and the root onboarding/read-order docs.
- `docs/` for shared blocker, performance, supervisor, storage, crypto, and
  status lessons.
- `NodeCore/` for language-neutral contracts, Docker runtime inventory, fixtures,
  and selected conformance proof artifacts.
- `Project/` for observational imports and reports. `Project/project.db` is
  generated and must not become operational chainstate.
- `Nodes/Reference/` for the local Bitcoin Core testnet4 recipe.

The root repository does **not** own live node datadirs, build outputs, local
DBs, logs, dependency caches, or nested port `.git` metadata.
Artifact cleanup and proof retention rules live in
[`artifact-retention.md`](artifact-retention.md).

## Port Repositories

These directories are independent implementation repos and are ignored by the
root repo:

- `Nodes/Python/` — scout/reference implementation.
- `Nodes/TypeScript/` — fast follower.
- `Nodes/Java/` — lead follower / proof surface.
- `Nodes/Cpp/` — systems follower.
- `Nodes/CSharp/` — RocksDB/native-crypto follower.
- `Nodes/Elixir/` — supervised follower.

Port repositories track their own source, tests, fixtures, docs, package/build
manifests, and intentional exported snapshots. They should ignore live datadirs,
local DBs, logs, dependency caches, and build output.

## Coordination Rule

Root docs can record cross-port facts, but each port must prove behavior in its
own repo. A blocker row from Java or Python is a handoff fact, not a validity
oracle for C#, TypeScript, C++, or Elixir.

## Checkpoint Rule

Use small checkpoints:

1. Root commits for shared contracts, topology, status, and lessons.
2. Port commits for implementation behavior and port-local tests.
3. NodeCore conformance artifacts only when they are intentional checkpoint
   evidence and named by fixture/category.

Do not commit a node's generated live state from the root repository.
