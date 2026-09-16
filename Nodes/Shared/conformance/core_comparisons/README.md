# Core-to-Core 5k comparison

Campaign: `20260916T061659Z-f0b45efc`. [Machine-readable result](core_5k_20260916T061659Z-f0b45efc.json).

**Result: passed.** One fresh warm-up and three fresh measured receivers all persisted height 5000, the expected checkpoint hash, and 4574 UTXOs. Campaign containers and successful volumes were removed cleanly after evidence capture.

| Run | Elapsed seconds | Observed peak receiver memory (MiB) | Observed peak CPU (%) | Header height |
|---|---:|---:|---:|---:|
| Warm-up (excluded) | 4.524 | 88.99 | 134.74 | 152650 |
| Measured 1 | 4.291 | 79.56 | 214.75 | 152650 |
| Measured 2 | 4.232 | 79.55 | 208.36 | 152651 |
| Measured 3 | 3.929 | 79.26 | 127.60 | 152651 |

Median **4.232 seconds**; range **3.929–4.291 seconds**; effective throughput **1181.5 blocks/second** (5000 divided by median end-to-end time).

Each receiver used Core 28.2, 4 CPUs, 4 GiB memory, `dbcache=450`, `par=4`, and `assumevalid=0`. Images were pinned by digest. Allocated datadir sizes are recorded in the JSON and include downloaded headers and debug logs.

A v1 P2P relay forwarded the full header stream and exactly 5000 blocks per receiver, withholding above-boundary block requests. Core performed validation itself. The relay was needed because stock Core 28.2 can connect queued blocks after requesting shutdown at 5000. Reference gained one header during this campaign; the actual per-run header heights appear above.

Timing includes receiver startup, header download, block sync/validation, relay forwarding overhead, and durable shutdown. Image/volume preparation, relay startup, and offline inspection are excluded. Source caches were warm; receiver state was fresh. Host caches were not cleared. Unrelated background services remained running and are recorded in the JSON.

Docker resource samples arrived about every 0.5 seconds on this host. Memory and CPU maxima are sampled observations, not instantaneous process peaks. CPU 100% means one CPU; relay resource use is excluded from these receiver statistics.

This is standalone comparison evidence. It does not earn port gates, establish tip readiness, or support an automatic ratio against differently instrumented port leaderboard results. Project DB, importers, and current-evidence selection were unchanged.

## Reproduce and validate

From the workspace root:

```bash
python3 Nodes/Reference/scripts/core_sync_comparison.py
python3 Nodes/Reference/scripts/core_sync_comparison.py --validate Nodes/Shared/conformance/core_comparisons/core_5k_20260916T061659Z-f0b45efc.json
python3 -m unittest discover -s Nodes/Reference/scripts -p 'test_*.py'
```

- Ten runner/relay tests passed, covering boundary withholding, malformed messages, state mismatch rejection, timing, timeout, aggregation, resource parsing, and cleanup ownership.
- Compose configuration and the Docker contract validator passed.
- Artifact validation and measured implementation digest checks passed. Project current evidence excludes this directory.
- The repository-wide documentation check reported an existing broken `substrate_pipeline.pdf` link in `Docs/rosettabitcoin_paper_publication.md:73`.

## Development attempts

Failed development attempts remain under ignored `Nodes/Reference/comparison-runtime/<campaign-id>/`, including their JSON/logs and retained diagnostic volumes. None contributes to the accepted median.

- `20260916T060711Z-7d57ce87`: TimeoutExpired: Command '['docker', 'stats', '--format', '{{json .}}', 'rb-core-20260916t060711z-7d57ce87-0']' timed out after 5 seconds
- `20260916T060846Z-2e510081`: RuntimeError: Inspection RPC did not become ready
- `20260916T061121Z-21c29bb1`: Post-run evidence review: Docker terminal codes prevented all resource samples; checkpoint/timing measurements retained, incomplete campaign excluded from acceptance.
- `20260916T061352Z-4e48713f`: RuntimeError: Resource sampling failed; retain diagnostics and rerun a new campaign
- `20260916T061445Z-9874e48e`: Post-run review: Compose replaced earlier stopped receivers; cleanup could not verify them and retained volumes. Timing/checkpoint/resource measurements preserved, campaign not accepted.
