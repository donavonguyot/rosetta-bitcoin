# Consensus Runway

File: `CONSENSUS_RUNWAY.md`

Consensus readiness is a staged runway from the offline script corpus to full
testnet4 tip. The source of truth is:

1. `Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json`
2. Project imports and projections in `Project/project.db`
3. port-owned compact proof JSON under `Nodes/Shared/conformance/results/`

Java and Python history explains where the rule cards came from. It is
provenance, not current per-port status.

## Stages

| Stage | Required proof | Project check | Does not count |
|-------|----------------|---------------|----------------|
| `script-corpus` | Port-owned `port.script_corpus_result.v1` artifact with `category=script_corpus`, `fixture_count=45`, `passed=45`, `failed=0`, runtime surface, verifier, native crypto backend, and per-fixture results | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage corpus --strict` | Shared manifest validation, another port's corpus artifact, partial corpus, fallback crypto |
| `5k` | Strict 5k baseline: RocksDB, native crypto, Docker local Reference P2P, fixed knobs, WAL enabled, `core_spendable_v1` with `chainstate_utxo_count=4574`, and clean script corpus | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 5k --strict` | RPC replay, WAL-off runs, alternate stores, copied state, non-Docker proof |
| `10k` | Imported sync/benchmark evidence with independent validation to at least height `10000` after the 5k baseline | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 10k --strict` | Header-only progress, trusted import, stale status prose |
| `50k` | Imported sync/benchmark evidence with independent validation to at least height `50000` after the 5k baseline | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 50k --strict` | Performance samples that do not validate blocks |
| `100k` | Imported sync/benchmark evidence with independent validation to at least height `100000` after the 5k baseline | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 100k --strict` | Any run with skipped consensus rules |
| `tip` | Imported status/proof evidence that the port is `blocks_current` and has independently validated through the current header tip | `python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage tip --strict` | Matching another node without independent validation, stale snapshots |

The full runway report is:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
```

## Rule Inventory

The rule ledger is the primary inventory of known Shared consensus rules:

```text
Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
```

Each rule card names fixture IDs, first observed height or blocker height, tags,
and artifact-backed evidence. A rule with `status=proved` can normalize stale
historical blocker notes in Project. For example, if a Markdown ledger still has
an old `open` note for a height but the Shared rule ledger marks that height's
rule as `proved`, Project reports the current blocker state as cleared.

Validate and refresh the generated readable matrix with:

```bash
python3 Nodes/Shared/consensus/tools/validate_consensus_ledger.py \
  Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json
python3 Nodes/Shared/consensus/tools/build_rule_matrix.py \
  --rules Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json \
  --output Nodes/Shared/consensus/generated/rule_matrix.md
```

`Docs/consensus-blockers-testnet4.md` and port blocker ledgers remain useful
explanations and provenance. They are imported evidence, not the current status
surface.

## Script-Corpus Artifact Shape

A port-owned corpus proof should use this shape:

```json
{
  "schema": "port.script_corpus_result.v1",
  "category": "script_corpus",
  "result": "passed",
  "implementation": "ExampleNode",
  "port": "example",
  "runtime_surface": "docker",
  "verifier": "example-native-script",
  "native_crypto_backend": "libsecp256k1",
  "fixture_count": 45,
  "passed": 45,
  "failed": 0,
  "results": [
    {
      "fixture_id": "scripts.p2wsh_op1_only_31842",
      "height": 31842,
      "result": "passed",
      "failure": ""
    }
  ]
}
```

`shared.script_fixtures.validation.v1` validates the fixture manifest only. It
must never count as a port's script-corpus proof.

## Blocker Discipline

When a port stops on an unsupported consensus rule:

1. Record exact blocker facts in the port blocker ledger.
2. Link or add the Shared fixture.
3. Link or add the rule card.
4. Prove the rule in that port with a corpus or live-sync artifact.
5. Rebuild Project and check the runway.

Do not clear a blocker by assuming success, skipping script verification,
trusting another port's result, or editing Markdown status by hand.
