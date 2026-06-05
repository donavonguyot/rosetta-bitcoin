# 5k Port Baseline

The 5k baseline is the first standard a port must clear before readiness claims
are treated as comparable. It is the birth certificate in the official benchmark
suite, not a permanent architecture lock-in.

The consensus runway continues this baseline toward longer validation stages and
tip. See `Nodes/Shared/consensus/CONSENSUS_RUNWAY.md`.
The benchmark suite continues through `shakedown_50k`, `performance_100k`,
`tip_once`, and `tip_maintenance`; see
`Nodes/Shared/conformance/BENCHMARK_CONTRACT.md`.

## Baseline Requirements

A baseline port must provide all of the following evidence:

In short: RocksDB, native crypto, `45/45`, Docker local Reference P2P,
`core_spendable_v1`, and Project preflight all have to agree.

| Requirement | Required value |
|-------------|----------------|
| Runtime state | RocksDB owns operational node truth |
| Crypto | Native secp256k1 backend selected and reported |
| Script corpus | Shared script corpus passes `45/45` |
| Runtime surface | Docker |
| Byte source | Local Reference Core over Bitcoin P2P |
| Commands | `docker_script_corpus` and `docker_proof_local` |
| Target | `target_height=5000`, `header_target_height=5000` |
| Proof state | Fresh Docker proof volume |
| Durability | WAL enabled, `rocksdb_wal_disabled=false` |
| Fetch/connect knobs | `prefetch_depth=4`, `script_runner_mode=parallel` |
| UTXO accounting | `core_spendable_v1`, `chainstate_utxo_count=4574` |
| Status/proof | Compact JSON imported by Project |

Shared fixture-manifest validation is not port proof. The script-corpus artifact
must be produced by the port's own verifier against the Shared corpus and use
`schema=port.script_corpus_result.v1`.

The expected block at height `5000` is:

```text
000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2
```

The proof artifact must expose the shared timing buckets that make later
comparisons useful:

```text
utxo_load
script_verify
utxo_apply
commit
block_connect_store_commit
```

## Diagnostic Only

These runs may be useful while building a port, but they do not earn 5k baseline
status:

- RPC replay or copied-byte replay;
- WAL-off runs;
- non-Docker runs;
- non-fresh datadirs or reused proof volumes;
- alternate storage backends;
- managed, pure, or fallback crypto in the proof path;
- partial script corpus results;
- missing fixed benchmark knobs;
- missing or wrong `core_spendable_v1` accounting.

Alternate stores and pure-language crypto can be research work after a port has
already proven the strict baseline. They are not comparable baseline evidence.

## Required Command Surface

Every baseline candidate needs these manifest command keys:

```text
docker_warm
docker_script_corpus
docker_proof_local
docker_status
```

`docker_warm` prepares images and dependencies before a benchmark campaign.
`docker_script_corpus` writes port-owned corpus proof JSON under
`Nodes/Shared/conformance/results/`. `docker_proof_local` is reserved for the
official Docker/local-reference P2P lane. If a port keeps RPC replay, storage
proof, or diagnostic sync commands, they must use explicit non-baseline command
keys.

## Project Acceptance

Project is the acceptance interface. Rebuild or refresh imports, then query the
baseline projection:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
python3 Project/scripts/report.py --db Project/project.db --section benchmark-suite
python3 Project/scripts/preflight_benchmark_gate.py --db Project/project.db --gate baseline_5k --port <port>
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --port <port> --strict
python3 Project/scripts/preflight_consensus_runway.py --db Project/project.db --port <port> --stage 5k --strict
python3 Nodes/Shared/conformance/tools/validate_script_corpus_result.py Nodes/Shared/conformance/results/<port>_script_corpus_*.json
```

For a report-only sweep across all ports:

```bash
python3 Project/scripts/preflight_port_baseline.py --db Project/project.db --all
```

`--strict` is the acceptance gate. Without `--strict`, the preflight is a
readable inventory that can show pending or mixed evidence without failing the
whole workspace.

## From Empty Port To Baseline

Use the shared template directory for the expected shape:

```text
Nodes/Shared/templates/port-baseline-5k/
```

Build in this order:

1. Implement the node's consensus, P2P, status, and chainstate path around a
   RocksDB operational store.
2. Wire native secp256k1 and make the proof fail if the native backend is not
   available.
3. Run the Shared script corpus and export compact JSON under
   `Nodes/Shared/conformance/results/`.
4. Validate the corpus artifact with
   `Nodes/Shared/conformance/tools/validate_script_corpus_result.py`.
5. Add the Docker manifest and required command keys.
6. Emit a status JSON and 5k benchmark JSON with the fixed baseline metadata.
7. Run `docker_warm`, `docker_script_corpus`, then `docker_proof_local` against
   local Reference Core.
8. Rebuild Project and pass `preflight_port_baseline.py --strict`.

The binary gate remains larger than this baseline: a serious node must still
reach and maintain current testnet4 tip while independently validating every
stored connected block.
