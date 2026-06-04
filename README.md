# RosettaBitcoin Workspace

`~/RB` is a multi-port Bitcoin testnet4 validation workspace and a single
root-owned monorepo. There is exactly one Git repository, at the workspace root.

## Canonical Read Order

1. [`AGENTS.md`](AGENTS.md) — operating rules and current sync cautions.
2. [`Docs/README.md`](Docs/README.md) — documentation ownership and cleanup index.
3. [`Docs/git-topology.md`](Docs/git-topology.md) — root vs port ownership.
4. [`Docs/port-status.md`](Docs/port-status.md) — Project status projection guide.
5. [`Nodes/Shared/SPEC.md`](Nodes/Shared/SPEC.md) — shared contracts and gate intent.
6. [`Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md`](Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md) — Docker runtime/proof rules.
7. [`Nodes/Shared/docker/PORT_DOCKER_INVENTORY.md`](Nodes/Shared/docker/PORT_DOCKER_INVENTORY.md) — current per-port Docker inventory.
8. `Nodes/Shared/docker/ports/<port>.docker.json` — executable Docker contract declaration for the target port.
9. [`Docs/artifact-retention.md`](Docs/artifact-retention.md) — proof/log/datadir retention rules.
10. Port README for the implementation being changed.

## Root-Owned Areas

| Path | Purpose |
|------|---------|
| `Docs/` | Shared lessons, blocker handoffs, Project query guides, topology |
| `Nodes/Shared/` | Cross-port contracts, fixtures, conformance manifests/results |
| `Project/` | Tracked mission-control SQLite DB, observational imports, and reports |
| `Nodes/` | Root-owned node implementation directories |
| `Nodes/Reference/` | Local Bitcoin Core testnet4 reference peer recipe |

## Compliance Boundaries

Core Node compliance requires separate evidence for consensus progress, native
storage, status import, and Docker runtime/proof behavior. A port must not claim
Core compliance if native mode depends on port-local SQLite for operational node
truth or if its Docker runtime surface is not documented in the Shared Docker
inventory. `Project/project.db` is allowed mission-control SQLite and is not a
runtime dependency.
Docker contract declarations are validated with:

```bash
python3 Nodes/Shared/docker/validate_docker_contract.py
```

Live datadirs, build outputs, local DBs, logs, dependency caches, and nested Git
metadata are not root-owned artifacts. Compact proof JSON that supports a
project claim belongs under `Nodes/Shared/conformance/results/`; see
[`Docs/artifact-retention.md`](Docs/artifact-retention.md).

## Binary Gate

The binary gate for any serious node remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Intermediate proofs and bounded syncs are useful evidence. They are not the
binary gate unless they reach and maintain current tip independently.
