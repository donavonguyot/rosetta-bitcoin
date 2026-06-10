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

Full-node capability contracts:

- `full_node_empty_state_tip_sync`
- `full_node_near_tip_maintenance`
- `full_node_public_peer_sync_probe`
- `full_node_peer_rotation_reconnect`
- `full_node_inbound_headers_serving`
- `full_node_inbound_block_serving`
- `full_node_block_inv_announcement`
- `full_node_mempool_valid_tx_admission`
- `full_node_mempool_invalid_tx_rejection`
- `full_node_tx_inventory_relay`
- `full_node_fork_choice_chainwork`
- `full_node_reorg_disconnect_reconnect`
- `full_node_crash_mid_commit_recovery`
- `full_node_restart_at_tip_soak`
- `full_node_bad_peer_protocol_safety`
- `full_node_resource_bound_safety`

Project may add capabilities when a new risk surface appears. Do not introduce
levels such as "level 1" or "gold" when adding them.

Full-node capabilities are not benchmark gates. They make network-peer reality
visible beside replay competence: public peer sync, serving, relay, reorgs,
crash recovery, and adversarial safety. Project derives `pass` only for
canonical clean `tip_once` and `tip_maintenance` evidence; all other full-node
capabilities stay `missing` until a port-owned explicit capability artifact
proves them. Baseline-retired ports are `not_applicable` for these rows.

## Registered Suites

`rb.shared_script_corpus`

- Manifest: `Nodes/Shared/conformance/fixtures/scripts/manifest.json`
- Suite version: `2026-06-07`
- Suite hash: `9f338ff205087144c38679ebd67bde5bf372bea3082922bde5f28013e4727d06`
- Case total: `45`
- Provenance: `rb_live_chain_regression`, `rb_synthetic_edge_case`
- Does not prove: community-complete Bitcoin script coverage, tip readiness, or every future consensus rule.

`bitcoin.bip340_schnorr_vectors`

- Manifest: `Nodes/Shared/testing/fixtures/bip340/test-vectors.csv`
- Source: `https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv`
- Suite version: `2026-06-07`
- Suite hash: `01c8cabba63b4c9b2f44c975902990086a4fe56eee9d265b187d1e2c1d98ccfb`
- Case total: `19`
- Provenance: `bip_standard_vector`
- Does not prove: ECDSA, Taproot tweak handling, block-connect usage, or every secp256k1 implementation behavior.

`rb.crypto_backend_equivalence_v1`

- Manifest: `Nodes/Shared/testing/fixtures/crypto_backend_equivalence_v1.json`
- Reference backend: `https://github.com/bitcoin-core/secp256k1`
- Suite version: `2026-06-07`
- Suite hash: `ef27cd3e8c2f7f83923d88aaee4d50ef9130fe42c5ccc14713478772d06209af`
- Case total: `27`
- Provenance: `bip_standard_vector`, `proof_derived`
- Does not prove: every libsecp256k1 internal test, every consensus path, or block-connect usage.

`rb.block_connect_backend_probe_v1`

- Manifest: `Nodes/Shared/testing/fixtures/block_connect_backend_probe_v1.json`
- Suite version: `2026-06-07`
- Suite hash: `7b1704a56dfdeeb72a7508db0fa85a4b63f44dbeb437f81a8bd5e364d304cb3d`
- Case total: `2`
- Provenance: `rb_live_chain_regression`, `proof_derived`
- Does not prove: long-sync safety, tip maintenance, or every future script template.

`rb.storage_codec_vectors_v1`

- Manifest: `Nodes/Shared/conformance/fixtures/chainstate_codec_v2_vectors.json`
- Suite version: `2026-06-07`
- Suite hash: `2e1a634d3ceb0bf8a723a35cc0619689e472686fef1a251cbbc8eff0f97da08c`
- Case total: `7`
- Provenance: `proof_derived`
- Does not prove: live sync safety, every future key family, or performance under long-run load.

`rb.storage_restart_probe_v1`

- Manifest: `Nodes/Shared/storage/STORAGE_GATE.md`
- Suite version: `2026-06-07`
- Suite hash: `d6e36c11a39c0b7189d39ad268c46ba1af942456fdc8189ece416b5c914296a2`
- Case total: `2`
- Provenance: `proof_derived`
- Does not prove: crash safety for every possible interruption point or long-run tip maintenance.

## Project Reports

```bash
python3 Project/scripts/report.py --db Project/project.db --section test-capabilities
python3 Project/scripts/report.py --db Project/project.db --section test-capability-gaps
python3 Project/scripts/report.py --db Project/project.db --section experiment-readiness
python3 Project/scripts/report.py --db Project/project.db --section full-node-capabilities
python3 Project/scripts/report.py --db Project/project.db --section full-node-gaps
python3 Project/scripts/report.py --db Project/project.db --section full-node-readiness
```

Use these reports to answer concrete safety questions:

- Can we try a pure crypto backend?
- Can we optimize block connect?
- Can we change storage codec keys?
- Can we rewrite P2P handshake timing?
- Which full-node behaviors are unproved beyond replay validation?

The answer should be `ready` or `blocked`, with exact missing contracts.

## Coverage Boundary

Line and branch coverage are optional diagnostics. They are not capability
contracts by themselves and are not readiness gates.
