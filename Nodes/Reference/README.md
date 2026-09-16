# Reference

Local Bitcoin Core testnet4 reference peer for the RosettaBitcoin workspace.

This node is a repeatability substrate, not a validation oracle. Port
implementations may download headers and blocks from it, but each port must
still independently validate every stored connected block.

## Start

```bash
cd <workspace-root>/Nodes/Reference
docker compose -f docker/docker-compose.yml up -d
```

The first run starts from an empty datadir and must sync from public testnet4.
Later runs reuse the Reference-owned runtime state directory:

```text
<workspace-root>/Nodes/Reference/bitcoin-core-testnet4
```

`<workspace-root>/Nodes/Reference` tracks the reproducible recipe. Core chainstate is
mutable runtime state under `bitcoin-core-testnet4/` and is intentionally
gitignored.

## Ports

Local P2P endpoint for ports:

```text
127.0.0.1:48333
```

Local RPC endpoint for status/fixture extraction:

```text
127.0.0.1:48332
```

RPC credentials are local development only:

```text
rpcuser=rosetta
rpcpassword=rosetta-dev-only
```

## Status

```bash
docker compose -f docker/docker-compose.yml exec bitcoin-core-testnet4 \
  bitcoin-cli -conf=/config/bitcoin.conf getblockchaininfo
```

## Boundary

Use this local Core node for deterministic development and multi-port block
serving. Public peer sync remains a required network reality gate before any
node can claim testnet4 participation.

Do not treat the Core datadir as source provenance. It is a local byte-serving
substrate; follower ports still validate independently.

## Core-to-Core 5k comparison

From the workspace root, with the existing Reference healthy and no other node
benchmarks running:

```bash
python3 Nodes/Reference/scripts/core_sync_comparison.py
```

The local images `bitcoin/bitcoin:28.2` and `python:3.12-alpine` must already be
available with repository digests. Pull them before the campaign if needed;
image preparation is outside measurement. The runner resolves immutable digests
and records both receiver and source identities. It loads
`Nodes/Shared/docker/reference_topology.env`, or the file selected by
`REFERENCE_TOPOLOGY_ENV`, and never starts or reconfigures the serving Reference.

The campaign runs one unmeasured warm-up and three sequential measurements. Each
receiver starts with an empty, unique Docker volume, 4 CPUs, 4 GiB memory,
`dbcache=450`, `par=4`, and `assumevalid=0`. It uses ordinary Core storage,
disables optional indexes/wallet/pruning, and has no published ports or public
peer discovery. Source and host caches are not cleared.

Core 28.2 can connect queued blocks after `stopatheight=5000` requests shutdown.
A small Python P2P relay therefore withholds requests and block payloads above
height 5000. It forwards headers unchanged, learns the bounded block hashes from
the header chain, and leaves consensus verification to Core. The receiver uses
v1 transport (`v2transport=0`) so the relay can frame messages. Reference remains
the sole upstream byte source. Relay forwarding overhead is included; relay
startup is outside timing. Relay CPU and memory are separate from receiver
resource measurements.

Elapsed time spans the receiver start request through process exit, including
startup, header sync, block validation, and durable shutdown. Volume preparation
and later inspection are excluded. A separate Core process opens the stopped
receiver's volume with networking disabled, checks persisted height/hash and
UTXO count, then shuts down cleanly. Acceptance requires height 5000, the Shared
5k checkpoint hash, and 4574 UTXOs. Headers can extend beyond 5000, and their
actual height is recorded. These timing boundaries and the relay mean this is
not automatically comparable to existing port leaderboard timings.

Docker statistics are collected at the daemon's one-second-or-faster stream
cadence; the artifact includes actual sample gaps, observed peak memory, sampled
CPU percentages (100% is one CPU), and allocated datadir size. Short runs and
sampling can miss instantaneous peaks. Missing statistics fail the campaign.

Compact JSON lives in `Nodes/Shared/conformance/core_comparisons/`, labeled
`comparison` with `binary_gate_status=not_attempted`. It is outside Project's
current-evidence selection and official port gates. To verify a result:

```bash
python3 Nodes/Reference/scripts/core_sync_comparison.py --validate <artifact.json>
python3 -m unittest discover -s Nodes/Reference/scripts -p 'test_*.py'
```

A campaign lock prevents overlapping invocations. Each sync has a 15-minute
timeout; failures stop the campaign without replacing a run. Raw logs remain in
ignored `comparison-runtime/`. Successful volumes are removed only after
inspection and artifact writing; failed-campaign volumes remain available for
diagnosis. Cleanup checks campaign ownership labels and never removes Reference
state. Failed artifacts remain explicit failed attempts, not accepted baselines.
