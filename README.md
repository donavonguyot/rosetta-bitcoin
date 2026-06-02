# Nodes Workspace

`~/Nodes` is a multi-port Bitcoin testnet4 validation workspace. The root repo
is the coordination layer; each serious node implementation keeps its own repo.

## Canonical Read Order

1. [`AGENTS.md`](AGENTS.md) — operating rules and current sync cautions.
2. [`docs/git-topology.md`](docs/git-topology.md) — root vs port ownership.
3. [`docs/port-status.md`](docs/port-status.md) — current all-port baseline.
4. [`NodeCore/SPEC.md`](NodeCore/SPEC.md) — shared contracts and gate intent.
5. Port README for the implementation being changed.

## Root-Owned Areas

| Path | Purpose |
|------|---------|
| `docs/` | Shared lessons, blocker handoffs, port matrix, topology |
| `NodeCore/` | Cross-port contracts, fixtures, conformance manifests/results |
| `Project/` | Observational status/proof imports and reports |
| `ReferenceNode/` | Local Bitcoin Core testnet4 reference peer recipe |

Live datadirs, build outputs, local DBs, logs, and port repository metadata are
not root-owned artifacts.

## Binary Gate

The binary gate for any serious node remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Intermediate proofs and bounded syncs are useful evidence. They are not the
binary gate unless they reach and maintain current tip independently.
