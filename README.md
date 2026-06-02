# RosettaBitcoin Workspace

`~/RB` is a multi-port Bitcoin testnet4 validation workspace and a single
root-owned monorepo. There is exactly one Git repository, at the workspace root.

## Canonical Read Order

1. [`AGENTS.md`](AGENTS.md) — operating rules and current sync cautions.
2. [`docs/README.md`](docs/README.md) — documentation ownership and cleanup index.
3. [`docs/git-topology.md`](docs/git-topology.md) — root vs port ownership.
4. [`docs/port-status.md`](docs/port-status.md) — current all-port baseline.
5. [`NodeCore/SPEC.md`](NodeCore/SPEC.md) — shared contracts and gate intent.
6. [`NodeCore/docker/DOCKER_RUNTIME_CONTRACT.md`](NodeCore/docker/DOCKER_RUNTIME_CONTRACT.md) — Docker runtime/proof rules.
7. [`NodeCore/docker/PORT_DOCKER_INVENTORY.md`](NodeCore/docker/PORT_DOCKER_INVENTORY.md) — current per-port Docker inventory.
8. `NodeCore/docker/ports/<port>.docker.json` — executable Docker contract declaration for the target port.
9. [`docs/artifact-retention.md`](docs/artifact-retention.md) — proof/log/datadir retention rules.
10. Port README for the implementation being changed.

## Root-Owned Areas

| Path | Purpose |
|------|---------|
| `docs/` | Shared lessons, blocker handoffs, port matrix, topology |
| `NodeCore/` | Cross-port contracts, fixtures, conformance manifests/results |
| `Project/` | Observational status/proof imports and reports |
| `Nodes/` | Root-owned node implementation directories |
| `Nodes/Reference/` | Local Bitcoin Core testnet4 reference peer recipe |

## Compliance Boundaries

Core Node compliance requires separate evidence for consensus progress, native
storage, status import, and Docker runtime/proof behavior. A port must not claim
Core compliance if native mode depends on SQLite for operational node truth or
if its Docker runtime surface is not documented in the NodeCore Docker inventory.
Docker contract declarations are validated with:

```bash
python3 NodeCore/docker/validate_docker_contract.py
```

Live datadirs, build outputs, local DBs, logs, dependency caches, and nested Git
metadata are not root-owned artifacts. Compact proof JSON that supports a
project claim belongs under `NodeCore/conformance/results/`; see
[`docs/artifact-retention.md`](docs/artifact-retention.md).

## Binary Gate

The binary gate for any serious node remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Intermediate proofs and bounded syncs are useful evidence. They are not the
binary gate unless they reach and maintain current tip independently.
