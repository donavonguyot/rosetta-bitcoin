# Test And Coverage Control Contract

Project owns the cross-port testing posture. Port test suites remain local to
each implementation, while `Project/project.db` indexes the command surface,
latest imported results, coverage capability, and critical-domain evidence.
Port tests should be written as standalone product-node tests. Benchmark gates,
telemetry schemas, timing buckets, and report artifact shapes are validated by
Shared/Project benchmark tooling because those contracts are expected to evolve.

## Command Categories

Every active port should expose or report these product-test surfaces:

| Category | Command key | Meaning |
|----------|-------------|---------|
| Unit and regression tests | `test_unit` | The normal local test suite for the port. |
| Coverage report | `test_coverage` | Report-only coverage instrumentation when the ecosystem has a real path. |
| Core regression lane | `test_core_regression` | Optional focused lane for consensus, storage, crypto, UTXO/accounting, and block-connect regressions. |
| Wire/codec lane | `test_wire_codec` | Optional lane for ports that intentionally harden broad protocol encoding/decoding surfaces. |
| Runtime smoke lane | `test_runtime_smoke` | Optional lane for CLI, settings, transport, and sync-path smoke tests. |
| Core coverage report | `test_coverage_core` | Optional readiness-focused coverage lane when broad coverage would be noisy. |
| Domain regressions | local port tests | Focused tests for consensus, storage, P2P, runtime, and reporting failures. |

Coverage percentages are report-only until Project has enough comparable data to
ratchet them productively. Global line/branch thresholds are not baseline
readiness. Prefer proof-backed critical-domain evidence and focused regressions
over broad percentage chasing.

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

Active contenders should have a supported `test_unit` command and visible
critical-domain coverage. `test_coverage` is expected to become available over
time, but missing coverage metrics are not a gate failure yet.

Optional lane commands are informational unless a port explicitly claims them.
Project's `baseline-par` level requires unit-test command visibility; it does
not require every port to copy Cpp's historical lane breadth or coverage shape.

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
python3 Project/scripts/preflight_test_coverage.py --db Project/project.db --all --level inventory
```

Use `--level baseline-par` to check active-contender unit-test visibility. Use
`--level coverage-control` only as a report-first coverage posture review until
thresholds are explicitly introduced.

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
Dry-run is the default. The capture script does not inspect benchmark artifacts,
validate benchmark telemetry, or enforce timing-bucket contracts.
