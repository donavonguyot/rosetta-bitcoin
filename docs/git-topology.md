# Nodes Git Topology

`~/Nodes` uses the root repository as the coordination and contract layer, plus
one implementation repository per serious node. This is the current policy until
the workspace deliberately migrates to a monorepo or formal submodules.

## Root Repository

The root repository owns shared infrastructure and cross-port truth:

- `AGENTS.md` and the root onboarding/read-order docs.
- `docs/` for shared blocker, performance, supervisor, storage, crypto, and
  status lessons.
- `NodeCore/` for language-neutral contracts, fixtures, and selected
  conformance proof artifacts.
- `Project/` for observational imports and reports. `Project/project.db` is
  generated and must not become operational chainstate.
- `ReferenceNode/` for the local Bitcoin Core testnet4 recipe.

The root repository does **not** own live node datadirs, build outputs, local
DBs, logs, dependency caches, or nested port `.git` metadata.

## Port Repositories

These directories are independent implementation repos and are ignored by the
root repo:

- `PythonNode/` — scout/reference implementation.
- `TypeScriptNode/` — fast follower.
- `JavaNode/` — lead follower / proof surface.
- `CppNode/` — systems follower.
- `CSharpNode/` — RocksDB/native-crypto follower.
- `ElixirNode/` — supervised follower.

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
