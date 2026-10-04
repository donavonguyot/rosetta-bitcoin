---
name: Mempool trace watcher
overview: Add a Reference Core activity probe and a long-lived watcher on the existing mempool capture tool, keep one busy testnet4 trace that meets coverage criteria, and replay it on Zig with extra replacement, reorder, and policy-divergence counts.
todos:
  - id: plan-doc
    content: Commit Docs/mempool-trace-watcher.plan.md on zig/trace-watcher
    status: pending
  - id: activity
    content: Add testnet4_activity.py, emit the activity line, and record watcher thresholds
    status: pending
  - id: watcher
    content: Add --watch, coverage keep/discard, GBT null, and per-window annotation counts
    status: pending
  - id: trace
    content: Run the watcher until one met trace is indexed, or lower min-tx once after 24h
    status: pending
  - id: replay
    content: Replay the kept trace on native and RocksDB and import the busy rung-0 evidence
    status: pending
isProject: false
---

# Mempool trace watcher

Branch `zig/trace-watcher` from `zig/mempool-mining` (`fec3b72`). Leave the dirty `zig/consensus-gaps` checkout and `zig/native-chainstate` alone. The quiet trace stays in [`Nodes/Shared/fixtures/mempool/index.json`](Nodes/Shared/fixtures/mempool/index.json) as the smoke fixture.

Commit 0, before any other change, writes this document to [`Docs/mempool-trace-watcher.plan.md`](Docs/mempool-trace-watcher.plan.md). Do not copy Reference RPC credentials into this file. Ports and the conf path are enough; the secrets stay in [`Nodes/Reference/bitcoin.conf`](Nodes/Reference/bitcoin.conf).

## Part 1 — activity line

New [`Project/scripts/testnet4_activity.py`](Project/scripts/testnet4_activity.py). One Reference RPC session (`Nodes/Reference/bitcoin.conf`, same cookie style as the capture tool):

- `getblockhash` / `getblockstats` for the last 2016 blocks: `txs`, `total_size`, `time`
- `getchaintxstats 2016`
- `getmempoolinfo` now

Emit one JSON object, schema `reference.activity.v1`: median and p95 tx-per-block, bursts (at least 5 consecutive blocks above 3× median, with start height and length), and current pool size and bytes. Write `Nodes/Shared/conformance/results/testnet4_activity_<date>.json`.

In that same file, record `watcher_thresholds` and a one-sentence reason. Defaults to bake into the watcher after seeing the line: `--open-pool` in 200–500 from the current pool and the burst sizes, `--open-rate` near 1.0 tx/s unless the measured arrival scale says otherwise.

## Part 2 — `--watch` on the capture tool

Extend [`Project/scripts/capture_mempool_trace.py`](Project/scripts/capture_mempool_trace.py). The existing one-shot path stays. `--watch` does not call `preflight()`'s fatal IBD exit.

- Every 30s: `getmempoolinfo` size and bytes, plus tx arrivals per second on a dedicated P2P connection over the last 120s. IBD (`initialblockdownload` or blocks != headers) and handshake failure are JSON log lines; the loop keeps polling.
- Open when pool size is at least `--open-pool` or the 120s rate is at least `--open-rate`. On open, take the existing topological `snapshot_preface`, then record with the current capture loop.
- Close at `--max-seconds` 3600, `--max-bytes` 200MB, or a reorg. Reorg means the captured `start_hash` is no longer on the main chain (`getblockheader` confirmations less than 1). Reason `reorg`, delete the directory, keep watching.
- Stage under `$RB_STATE_ROOT/traces/inflight`, not in the fixture tree. Coverage is computed from the arranged trace before the canonical tar hash:
  - `tx_count >= --min-tx` (2000)
  - `replacements >= 1`: `assign_expected` already sets `expected_layer1 = input_spent_in_pool` on an overlapping unconfirmed input
  - `out_of_order >= 1`: a tx whose in-trace parent has a later `capture_seq` (preface parents do not count). Mark `out_of_order` on that annotation
  - `policy_divergence_boundaries >= 1`: after the same accept/evict walk as `assign_expected` (confirmed txids, block-spent outpoints, then descendants), XOR-SHA256 of the remaining accepted wtxids differs from that boundary's `core_set_hash`
  - `blocks >= 3`
- All met: hash, rename to `trace-<hash>/`, append `index.json` with `coverage: met` and the counts. Otherwise delete the staging directory and log `coverage: unmet`. At most `--keep` 3 met traces for testnet4; then exit 0. `--max-watch-seconds` defaults to 86400.
- Every poll, open, close, keep, and discard is one JSON line on stdout and `$RB_STATE_ROOT/traces/watch.log`.
- Manifest gains `trigger`, `thresholds`, `coverage`, and `discard_reason` when a window is discarded before publish. Published traces omit `discard_reason`.

Fixes in the same commit:

- In `take_block`, if `last_gbt` is missing or `captured_unix_ms` is older than the previous block event's arrival, store `gbt: null`. [`Nodes/Zig/src/rung0.zig`](Nodes/Zig/src/rung0.zig) already turns a missing `fees_sat` or a zero core fee into `ratio_micros: null`, so a stale template stops being a comparable ratio. Extend `self_test` for that case.
- Each tx annotation gets `input_count`. Manifest `per_window` is one row per 1000 events: tx count, input count, signature-bearing input count (an input with a witness item or scriptSig push that `is_signature` already accepts), and payload bytes.

## Part 3 — replay the kept trace

Reporting only in [`Nodes/Zig/src/rung0.zig`](Nodes/Zig/src/rung0.zig) and the two writers in [`Nodes/Zig/src/main.zig`](Nodes/Zig/src/main.zig). No pool, connect, or script changes.

- Replacements: count of `expected_layer1 = input_spent_in_pool` and the verdict each received.
- Out of order: count of annotations with `out_of_order` whose verdict is `accepted`.
- Divergent boundaries: each height where the port set hash differs from `core_set_hash`, with both hashes.

Replay procedure: copy `~/.rblab/zig/mempool-rung0-native` only if its tip is still an ancestor of the new `start_hash`; otherwise sync a fresh `trace-watcher-native` datadir. Same for RocksDB from `mempool-rung0`. `sync --target <start_height>`, require tip hash == `start_hash`, then `mempool-replay` and `build-template` on both stores. The mutation file is the one `publish()` already generates with seed `0x524F5345545441`.

Oracle, checked into the evidence files: every verdict equals `expected_layer1`; every mutation reason matches; native and RocksDB set hashes match after every block; the divergent heights equal `manifest.coverage` predicted heights.

Evidence: `zig_mempool_rung0_busy_host_<date>.json` and `zig_mining_rung0_busy_host_<date>.json`, schemas `port.mempool.rung0.v1` and `port.mining.rung0.v1`, `fixture: live`, `trace_hash` of the new trace. Index under claims `mempool` and `mining` with empty benchmark `gate_id`. Provenance `run_ref` `zig-trace-watcher`. Import stored artifacts only. Zig port status and canonical benchmark rows stay put.

## If the first day misses

Start the watcher in the background against Reference Core. If 24 hours produce no met trace, commit the watch log plus the activity line, set `--min-tx` to 500 with that change recorded on the activity JSON, and run one more 24 hour watch. Do not start mainnet, policy, or Docker work.

Commits: (0) plan, (1) activity script and line, (2) watcher, manifest fields, GBT null, per-window counts, (3) kept trace, mutation corpus, index, (4) replay evidence.
