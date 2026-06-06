# RosettaBitcoin Workspace

`~/RB` is a multi-port Bitcoin testnet4 validation workspace and a single
root-owned monorepo. There is exactly one Git repository, at the workspace root.

## Canonical Read Order

1. [`AGENTS.md`](AGENTS.md) — operating rules and current sync cautions.
2. [`Docs/README.md`](Docs/README.md) — documentation ownership and cleanup index.
3. [`Docs/git-topology.md`](Docs/git-topology.md) — root vs port ownership.
4. [`Docs/port-baseline-5k.md`](Docs/port-baseline-5k.md) — strict first readiness baseline and benchmark-suite entry point.
5. [`Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`](Nodes/Shared/consensus/CONSENSUS_RUNWAY.md) — corpus-to-tip consensus path.
6. [`Docs/port-status.md`](Docs/port-status.md) — Project status projection guide.
7. [`Nodes/Shared/testing/TEST_COVERAGE_CONTRACT.md`](Nodes/Shared/testing/TEST_COVERAGE_CONTRACT.md) — Project-indexed test and coverage posture.
8. [`Nodes/Shared/SPEC.md`](Nodes/Shared/SPEC.md) — shared contracts and gate intent.
9. [`Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md`](Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md) — Docker runtime/proof rules.
10. `Nodes/Shared/docker/ports/<port>.docker.json` — executable Docker contract declaration for the target port.
11. [`Nodes/Shared/docker/PORT_DOCKER_INVENTORY.md`](Nodes/Shared/docker/PORT_DOCKER_INVENTORY.md) — Project query guide for Docker coverage and command surfaces.
12. [`Docs/artifact-retention.md`](Docs/artifact-retention.md) — proof/log/datadir retention rules.
13. Port README for the implementation being changed.

## Root-Owned Areas

| Path | Purpose |
|------|---------|
| `Docs/` | Shared lessons, blocker handoffs, Project query guides, topology |
| `Nodes/Shared/` | Cross-port contracts, fixtures, conformance manifests/results |
| `Project/` | Tracked mission-control DB, observational imports, and reports |
| `Nodes/` | Root-owned node implementation directories |
| `Nodes/Reference/` | Local Bitcoin Core testnet4 reference peer recipe |

## Compliance Boundaries

The official benchmark suite is `baseline_5k`, `shakedown_50k`,
`performance_100k`, `tip_once`, and `tip_maintenance`. The first comparable
readiness standard is the 5k baseline: RocksDB runtime truth, native crypto, the
shared `45/45` script corpus, Docker local Reference P2P proof, fixed benchmark
knobs, `core_spendable_v1` UTXO accounting, and Project-importable artifacts.
See [`Docs/port-baseline-5k.md`](Docs/port-baseline-5k.md).

Core Node compliance requires separate evidence for consensus progress, RocksDB
runtime truth, status import, and Docker runtime/proof behavior. Project
mission control is not a runtime dependency.
Docker contract declarations are validated with:

```bash
python3 Nodes/Shared/docker/validate_docker_contract.py
```

Project reports the 5k baseline posture with:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-lifecycle
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port <port> --strict
```

Project reports consensus readiness from the Shared rule ledger through staged
sync evidence with:

```bash
python3 Nodes/Shared/consensus/tools/validate_consensus_ledger.py Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 5k --strict
```

Project reports test and coverage posture separately from benchmark readiness:

```bash
python3 Project/scripts/report.py --db Project/project.db --section test-coverage
python3 Project/scripts/report.py --db Project/project.db --section critical-test-domains
python3 Project/scripts/preflight_test_coverage.py --db Project/project.db --all --level inventory
```

Coverage is optional local telemetry. Product-test par starts with unit command
visibility, imported unit results, and critical-domain evidence.

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
