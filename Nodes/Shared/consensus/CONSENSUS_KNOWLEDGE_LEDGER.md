# Shared Consensus Knowledge Ledger v1

The consensus knowledge ledger is a language-neutral map of rules, blockers,
fixtures, and proof evidence. It exists so ports can learn from each other
without treating another port's runtime as an oracle.

## Scope

Ledger v1 starts with the Shared script corpus because that is the first shared
cross-port consensus surface with stable fixtures. Each rule card must point to
real evidence:

- one or more script fixture IDs from
  `Nodes/Shared/conformance/fixtures/scripts/manifest.json`
- optional blocker rows from `Docs/consensus-blockers-testnet4.md`
- optional port proof artifacts from `Nodes/Shared/conformance/results/`

The ledger does not declare that a port is live-sync complete. It only records
which fixtures and rules have been independently proved by artifacts.

## Rule Card Fields

Rule cards live in `Nodes/Shared/consensus/rules/*.json` and use schema
`shared.consensus_rule.v1`.

Required fields:

| Field | Meaning |
|-------|---------|
| `rule_id` | Stable lower-case identifier |
| `category` | Consensus area, for v1 usually `script` |
| `title` | Human-readable rule title |
| `chain` | Chain/network, usually `testnet4` |
| `status` | `fixture_backed`, `blocker_backed`, `proved`, or `candidate` |
| `fixture_ids` | Script corpus fixture IDs that exercise this rule |
| `required_rules` | Manifest rule labels copied from fixture metadata |
| `tags` | Searchable rule groups/templates |
| `first_observed` | Optional height/tx/input from the fixture source |
| `evidence` | Artifact-backed observations by port |
| `notes` | Short porting notes |

## Evidence Rules

- A fixture-backed rule may remain useful even when no current port result is
  attached yet.
- A port-specific evidence row must reference a real artifact path.
- `go_passed` in the script matrix is not a substitute for a Go rule card. The
  evidence row should point at the Go result JSON that proves the fixture.
- A local-reference replay artifact is replay telemetry evidence; it is not a
  substitute for script-corpus evidence unless it names the relevant fixture.

## Tooling

Regenerate the v1 script rule ledger from the shared manifest:

```bash
python3 Nodes/Shared/consensus/tools/seed_script_rules.py \
  --manifest Nodes/Shared/conformance/fixtures/scripts/manifest.json \
  --results-dir Nodes/Shared/conformance/results \
  --output Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
```

Validate rule cards:

```bash
python3 Nodes/Shared/consensus/tools/validate_consensus_ledger.py \
  Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
```

Generate a readable rule matrix:

```bash
python3 Nodes/Shared/consensus/tools/build_rule_matrix.py \
  --rules Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json \
  --output Nodes/Shared/consensus/generated/rule_matrix.md
```

## How Ports Use It

When a port hits a blocker:

1. Record the exact blocker in that port's blocker ledger.
2. Add or identify the Shared fixture that reproduces it.
3. Link the fixture to an existing or new rule card.
4. Prove the rule in that port and attach the result artifact.

This keeps the shared knowledge ledger factual and replayable while preserving
port independence.
