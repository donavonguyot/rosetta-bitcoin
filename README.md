# RosettaBitcoin

RosettaBitcoin is a multi-port Bitcoin testnet4 validation workspace and a
single root-owned monorepo. There is exactly one Git repository, at the
workspace root.

## What This Is

RosettaBitcoin compares independently implemented Bitcoin testnet4 validation
nodes across language ports. The project is evidence-first: public claims are
grounded in Project reports, Shared conformance fixtures, curated evidence
selection, and compact proof artifacts.

The goal is not a wallet, custody system, production security product, or
shortcut around Bitcoin validation. The goal is to make each serious port prove
what it can actually validate, store, resume, and maintain on testnet4 without
treating another implementation as an oracle.

The binary end gate remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Bounded gates and benchmark lanes are useful evidence. They are not the binary
gate unless they reach and maintain current tip independently.

## Ports

RosettaBitcoin contains implementation directories for C++, C#, Elixir, Go,
Java, OCaml, Python, Rust, Swift, TypeScript, and Zig.

`Nodes/Reference/` contains the local Bitcoin Core recipe used as a byte source
and comparison surface. Port readiness, benchmark rank, evidence selection, and
consensus runway state are reported by Project, not by this README.

## Evidence Orientation

Do not treat README prose as a status table. Use Project reports for the live
mission-control view before quoting port posture, readiness, benchmark rank,
current evidence, or consensus runway state.

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section current-evidence
```

## Invitation To Bitcoin Node Reviewers

Correctness review from Bitcoin Core contributors and other node implementers is
welcome, especially when it sharpens consensus fixtures, script behavior,
P2P/sync assumptions, storage safety, benchmark claims, or evidence boundaries.

This is an invitation, not an obligation. There is no expectation of review
bandwidth, no roadmap dependency on a response, and no request for public
critique. General correctness notes and semantic-drift observations can use
GitHub Issues after publication; security-sensitive reports should follow
[`SECURITY.md`](SECURITY.md).

Reference Core is used as a byte source and comparison surface. It is not a
RosettaBitcoin validity oracle. RosettaBitcoin ports stand or fall on their own
Project-imported evidence, Shared fixtures, and port-owned proof artifacts. See
[`Docs/core-btcg-comparison-lane.md`](Docs/core-btcg-comparison-lane.md).

Contributors looking for open experiments — benchmark races, new language
ports, the must-reject corpus, and the standing native-backend dares — should
start with [`CHALLENGES.md`](CHALLENGES.md).

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

The official benchmark suite and gate labels live in
[`Nodes/Shared/conformance/BENCHMARK_CONTRACT.md`](Nodes/Shared/conformance/BENCHMARK_CONTRACT.md)
and Project reports. The first comparable readiness standard is the 5k baseline:
RocksDB runtime truth, native crypto, the shared `45/45` script corpus,
Docker local Reference P2P proof, fixed benchmark knobs, `core_spendable_v1`
UTXO accounting, and Project-importable artifacts. See
[`Docs/port-baseline-5k.md`](Docs/port-baseline-5k.md).

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
python3 Project/scripts/report.py --db Project/project.db --section leaderboard --gate shakedown_50k
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port <port> --strict
```

Benchmark leaderboards are generated from comparable canonical artifacts that
satisfy the shared validator and import as `artifact_quality=canonical`.
Long-run gates also require `telemetry_quality=clean`; `shakedown_50k` is the
telemetry discipline gate before `performance_100k`, and `post_100k_to_tip`
is the immediate tip-readiness lane from canonical 100k state. Historical evidence
remains queryable, but it does not support current rank.

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

## Public Release Posture

This workspace is being prepared for publication at
`donavonguyot/rosetta-bitcoin`. The local working-directory path is not a
separate public project identity.

Public status claims must come from Project reports and Project-backed
RosettaBitcoin evidence, not hand-maintained prose or narrative summaries.
RosettaBitcoin uses the MIT License and plans to use GitHub private
vulnerability reporting when public visibility is enabled. Final publication
still requires a Project evidence refresh, artifact/ignore review, and
repository security settings check.

Start with [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`SECURITY.md`](SECURITY.md).

## Binary Gate

The binary gate is repeated here because it is the project boundary that matters
most:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

Intermediate proofs and bounded syncs are useful evidence. They are not the
binary gate unless they reach and maintain current tip independently.

Reusable, independently buildable crypto packages live under `Libraries/`. They
are root-owned source directories with package-local metadata and licenses, not
nested Git repositories. See `Libraries/README.md` and Project `crypto-lanes`.
