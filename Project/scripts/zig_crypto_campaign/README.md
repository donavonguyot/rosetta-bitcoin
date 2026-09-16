# Independent Zig optimization campaign

This tooling belongs to Project and produces comparison evidence, not canonical
baseline claims. The original package and common instrumented node are preserved
by the annotated tag in `baseline.json`. The user working tree is not reset.
The four arithmetic deltas in `stages/` are independently authored Zig changes,
not C translations. Production explanations live in the package's DERIVATIONS.md.

Prerequisites: Zig 0.16.0, Python, Docker, CMake, the existing local Reference P2P
service on `rosetta-reference-node_default`, and the pinned reference archive.
The base image, Zig downloads, compiler packages, RocksDB and reference are pinned
in `Dockerfile` and `toolchains.lock.json`. Commands run from the workspace root.

1. Run `python3 Project/scripts/zig_crypto_campaign/prepare.py`. It reconstructs
   the original package archive and absent stage snapshots from the scoped tag
   and patches; existing measurements are preserved. The node source must match
   the recorded common node digest. To reproduce later, use a separate root-owned
   worktree at the recorded source, never replace an active node's source.
2. If absent, run `python3 Project/scripts/zig_crypto_campaign/prepare.py --reference`
   to build the test-only reference. It verifies the archive checksum.
3. For each of `original`, `stage1`, `stage2`, `stage3`, `stage4`, run
   `python3 Project/scripts/zig_crypto_campaign/stage.py NAME --existing`.
   Run sequentially without other benchmarks. Then run `counts.py`; its counters
   modify disposable test copies only, never candidate runtime code.
4. Build each of `original`, `optimized`, `c_control` with
   `python3 Project/scripts/zig_crypto_campaign/build.py VARIANT`. Optimized uses
   the current package; original uses the archived package. All use one node
   digest. Images record package identity and do not use mutable tags for runs.
5. Run `python3 Project/scripts/zig_crypto_campaign/validate_candidate.py`.
   This runs the stronger campaign gates, creates test-only probe/reject images,
   compares 10,005 generated API cases, and traces a separate 5k replay.
6. Run `python3 Project/scripts/zig_crypto_campaign/measure.py` alone. A shared
   lock serializes all warmups and measured node runs. It also measures all three
   component executables on the same Docker architecture and benchmark inputs.
7. Run `python3 Project/scripts/zig_crypto_campaign/assemble.py`. It validates
   retention and canonical-report stability, writes a dedicated comparison and
   uncurated candidate artifacts, and prints the comparison table. To validate
   and display a report later, run `comparison.py PATH_TO_COMPARISON_JSON`.

Comparison reports live outside ordinary `results/` discovery, under
`Nodes/Shared/conformance/crypto_comparisons/`. The label `campaign_comparable`
is only a comparison-report label. Historical lane validation floors remain
unchanged. Neither candidate files nor C controls are automatically selected in
`current_evidence.json` or imported as canonical leaderboard claims.

Node worker CPU is measured with CLOCK_THREAD_CPUTIME_ID around each scheduler
loop; high-resolution elapsed uses CLOCK_MONOTONIC over the same coverage.
Verifier creation/destruction is excluded. Both include interpreter, hashing,
and scheduling. The legacy `script_worker_cpu_ms` remains elapsed time.
The new explicitly named nanosecond fields coexist with legacy timing buckets;
read their suffixes rather than assuming every bucket value is milliseconds.

Each measured and warmup run has a fresh volume. Successful campaign volumes are
removed after settled status capture; failed/fault-injected volumes are preserved.
No existing user datadir is used. Logs, source snapshots and build contexts stay
ignored under `Project/.campaigns/zig-opt`. The original source archive is
reconstructible from the tagged commit; all image and source identities accompany
published evidence. These tests provide no signing or side-channel assurances.
