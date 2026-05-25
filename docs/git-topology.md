# Nodes Git Topology

`~/Nodes` uses one coordination repository at the workspace root plus one
implementation repository per node.

## Root Repository

The root repository tracks shared operating context only:

- `AGENTS.md`
- shared strategy notes
- blocker ledger and cross-port handoffs
- port status summaries

The root repository does not own node source trees. Each node keeps its own git
history so language-specific work can move independently.

## Node Repositories

Each serious node should have its own repository:

- `PythonNode/`
- `TypeScriptNode/`
- `CppNode/`
- future `JavaNode/`

Node repositories track source, tests, fixtures, docs, package/build manifests,
and intentional exported snapshots. They should ignore live datadirs, local DBs,
logs, dependency caches, and build output.

## Checkpoint Rule

Root checkpoints should describe strategy or handoffs. Node checkpoints should
describe implementation behavior. Do not commit a node's generated state from
the root repository.
