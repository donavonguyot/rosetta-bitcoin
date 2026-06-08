# Contributing

RosettaBitcoin is evidence-first. Contributions should improve independently
validated node behavior, shared contracts, fixtures, proof artifacts, or the
documentation that keeps those claims honest.

## Before You Start

Read:

- `AGENTS.md`
- `README.md`
- `Docs/README.md`
- `Docs/port-baseline-5k.md`
- `Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`
- `Nodes/Shared/conformance/BENCHMARK_CONTRACT.md`
- `Nodes/Shared/CODE_DOCUMENTATION.md`
- `Docs/artifact-retention.md`

Use Project reports for current status. Do not rely on static README tables or
old archive notes for current claims.

## Evidence Rules

- Keep ports independent. Do not treat Reference Core, btcg, another RB port,
  or retired archive material as a validity oracle.
- Consensus changes should include or update fixtures, rule cards, blocker
  facts, and proof artifacts where applicable.
- Proof artifacts that support project claims belong under
  `Nodes/Shared/conformance/results/` and should be selected through current
  evidence when they are meant to affect Project status.
- Bounded gates such as `baseline_5k`, `shakedown_50k`, and
  `performance_100k` are evidence. They are not the binary gate.

The binary gate remains:

```text
From empty local state on Bitcoin testnet4, the node reaches and maintains tip
while independently validating every stored connected block.
```

## Artifact Boundaries

Do not commit runtime state, datadirs, block files, chainstate, local DBs, logs,
dependency trees, generated build output, Docker volumes, private env files, or
nested `.git` histories.

Historical RosettaBitcoin archive material is provenance only. If a historical
fact matters, rewrite it into an RB-native doc, Shared contract, fixture, rule
card, or compact proof artifact before using it to support a claim.

## Pull Request Expectations

Keep changes narrowly scoped. Include the relevant Project report, preflight,
test, corpus, benchmark, or artifact validation command in the PR description.
If a change is docs-only, say so explicitly. Documentation passes must follow
`Nodes/Shared/CODE_DOCUMENTATION.md`; run
`python3 Project/scripts/check_doc_drift.py` after Markdown edits.
