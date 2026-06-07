# Test And Coverage Control Contract

Project owns the cross-port testing posture. Port test suites remain local to
each implementation, while `Project/project.db` indexes the command surface,
latest imported unit results, optional coverage telemetry, and critical-domain
evidence.
Port tests should be written as standalone product-node tests. Benchmark gates,
telemetry schemas, timing buckets, and report artifact shapes are validated by
Shared/Project benchmark tooling because those contracts are expected to evolve.

## Command Categories

Every active port should expose or report these product-test surfaces:

| Category | Command key | Meaning |
|----------|-------------|---------|
| Unit and regression tests | `test_unit` | The normal local test suite for the port. |
| Coverage report | `test_coverage` | Optional local telemetry when explicitly enabled; not default par. |
| Domain regressions | local port tests | Focused tests for consensus, storage, P2P, runtime, and reporting failures. |

Coverage percentages are optional telemetry. They are not readiness, not par,
not a ratchet, and not expected across ports. Prefer proof-backed
critical-domain evidence and focused regressions over broad percentage chasing.

Benchmark and conformance commands such as `docker_script_corpus`,
`docker_storage_proof`, `docker_proof_local`, `docker_proof_50k`, and
`docker_proof_100k` remain important Project surfaces, but they are not
port-level test coverage posture. They belong to conformance, benchmark, and
runway preflights, not `preflight_test_coverage.py`.

## Critical Domains

The current Project domain matrix tracks:

| Domain | Evidence source |
|--------|-----------------|
| `script_verification` | Shared corpus proof plus focused product regressions. |
| `sighash_taproot_witness` | Shared corpus coverage and focused product regressions when imported. |
| `utxo_apply_undo_accounting` | Product tests or current proof evidence for UTXO apply/undo/accounting. |
| `block_connect` | Product block-connect regressions or current independently validated sync evidence. |
| `rocksdb_persistence_restart` | Product persistence/restart tests or current RocksDB-backed evidence. |
| `p2p_fetch_handshake` | Product P2P handshake tests or current local Reference P2P evidence. |
| `node_status_reporting` | Product status/reporting smoke, not benchmark artifact schema validation. |

## Lifecycle Expectations

Active contenders should have a supported `test_unit` command, latest imported
unit-test result telemetry when captured, and visible critical-domain evidence.
Missing coverage metrics are not a gap.

Project's `baseline-par` level requires unit-test command visibility. It does
not require any port to copy Cpp's historical lane breadth, Java's coverage
discipline, or any global percentage posture.

Capability contracts are the richer safety-net vocabulary for optimization and
experiments. See `TEST_CAPABILITY_CONTRACT.md`. They replace maturity-level
language with named pass/fail/missing risk surfaces, provenance, and suite
hashes. Coverage percentages remain optional diagnostics beneath that layer.

Active-development ports are inventory-first. Missing long-run or coverage
evidence should not be treated as a failure unless the port claims that gate.

Baseline-retired ports keep their existing test and baseline evidence. They do
not need new coverage work unless explicitly reactivated.

## Project Queries

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/capture_test_coverage.py --db Project/project.db --all --dry-run
python3 Project/scripts/report.py --db Project/project.db --section test-commands
python3 Project/scripts/report.py --db Project/project.db --section test-coverage
python3 Project/scripts/report.py --db Project/project.db --section critical-test-domains
python3 Project/scripts/report.py --db Project/project.db --section test-capabilities
python3 Project/scripts/report.py --db Project/project.db --section experiment-readiness
python3 Project/scripts/preflight_test_coverage.py --db Project/project.db --all --level inventory
```

Use `--level baseline-par` to check active-contender unit-test visibility. Use
`--level coverage-control` only for explicit local coverage experiments.

Use benchmark-specific tools for benchmark correctness:

```bash
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate baseline_5k --all
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --all
```

Those checks may validate telemetry, timing buckets, canonical benchmark gates,
and Project-importable proof shape. Port unit tests should not ossify those
details.

## Artifact Shapes

Compact testing artifacts use stable schema names:

- `port.test_result` for a command result.
- `port.coverage_summary` for coverage metrics.
- `port.domain_coverage` for explicit domain claims.

Historical importer aliases may remain internal for old artifacts, but new
docs, reports, and curated artifacts should use the stable names above.

`Project/scripts/capture_test_coverage.py` writes curated test and coverage
JSON under `Nodes/Shared/testing/results/` when run explicitly with `--run`.
Dry-run is the default. `--all --run` captures unit-test telemetry only;
coverage capture requires `--include-coverage` and a deliberately supported
coverage command. The capture script does not inspect benchmark artifacts,
validate benchmark telemetry, or enforce timing-bucket contracts.
