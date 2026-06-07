# Test Capability Contract

Project tracks test capability contracts so ports can optimize or try new
backends with a real safety net. These contracts are not maturity levels,
rankings, badges, or global coverage thresholds.

## Contract Shape

Capability artifacts use schema `port.test_capability_contract.v1` and live
under `Nodes/Shared/testing/results/`.

Each contract row must include:

| Field | Meaning |
|-------|---------|
| `contract_id` | Stable contract row identifier within the artifact. |
| `capability` | Risk surface being proven, such as `shared_script_corpus` or `p2p_deferred_handshake`. |
| `status` | One of `pass`, `fail`, `missing`, or `not_applicable`. |
| `scope` | Execution surface such as `host`, `docker`, `native`, `pure`, or `local_reference`. |
| `backend` | Relevant backend, for example `rocksdb`, `libsecp256k1`, or `pure_crypto`. |
| `evidence_kind` | Evidence family: `suite`, `test_result`, `storage_proof`, `baseline_5k`, `current_evidence`, etc. |
| `evidence_path` | Artifact, fixture, or proof path that supports the claim. |
| `command_key` | Project command key when the evidence comes from a command surface. |
| `provenance` | One or more allowed provenance classes. |
| `does_not_prove` | Explicit boundary for what the evidence cannot claim. |
| `blocking_for` | Experiment or optimization surfaces this contract gates. |

When a contract reports case counts, it must also include `suite_id`,
`suite_version`, and `suite_hash`. Denominators must never be reported naked.
For example, `45/45` is only meaningful as:

```text
suite=rb.shared_script_corpus result=45/45 suite_hash=<sha256> provenance=...
```

## Provenance Classes

Allowed provenance values:

| Provenance | Meaning |
|------------|---------|
| `bip_standard_vector` | Vector published with a Bitcoin Improvement Proposal. |
| `bitcoin_core_upstream_vector` | Vector or behavior anchored in Bitcoin Core upstream tests. |
| `libsecp256k1_upstream_vector` | Vector or behavior anchored in Bitcoin Core's secp256k1 library. |
| `rb_live_chain_regression` | Fixture harvested from RosettaBitcoin live-chain blocker work. |
| `rb_synthetic_edge_case` | Project-authored synthetic edge case. |
| `port_regression` | Local port test protecting a known implementation behavior. |
| `proof_derived` | Contract inferred from Project-imported proof evidence. |

Community-anchored vectors and project-local regressions are both valuable, but
they must remain distinct in reports.

## Initial Capabilities

Core safety contracts:

- `unit_surface`
- `shared_script_corpus`
- `sighash_and_witness_regressions`
- `utxo_apply_undo_accounting`
- `block_connect_local_reference`
- `rocksdb_restart_persistence`
- `p2p_deferred_handshake`
- `status_reporting`

Experiment-focused contracts:

- `crypto_bip340_vectors`
- `crypto_libsecp256k1_equivalence`
- `crypto_backend_reporting`
- `script_corpus_with_backend`
- `block_connect_with_backend`
- `storage_codec_vectors`
- `storage_restart_after_codec_change`

Project may add capabilities when a new risk surface appears. Do not introduce
levels such as "level 1" or "gold" when adding them.

## Registered Suites

`rb.shared_script_corpus`

- Manifest: `Nodes/Shared/conformance/fixtures/scripts/manifest.json`
- Suite version: `2026-06-07`
- Suite hash: `9f338ff205087144c38679ebd67bde5bf372bea3082922bde5f28013e4727d06`
- Case total: `45`
- Provenance: `rb_live_chain_regression`, `rb_synthetic_edge_case`
- Does not prove: community-complete Bitcoin script coverage, tip readiness, or every future consensus rule.

## Project Reports

```bash
python3 Project/scripts/report.py --db Project/project.db --section test-capabilities
python3 Project/scripts/report.py --db Project/project.db --section test-capability-gaps
python3 Project/scripts/report.py --db Project/project.db --section experiment-readiness
```

Use these reports to answer concrete safety questions:

- Can we try a pure crypto backend?
- Can we optimize block connect?
- Can we change storage codec keys?
- Can we rewrite P2P handshake timing?

The answer should be `ready` or `blocked`, with exact missing contracts.

## Coverage Boundary

Line and branch coverage are optional diagnostics. They are not capability
contracts by themselves and are not readiness gates.
