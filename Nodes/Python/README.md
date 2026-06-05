# pybitnode

Binary-compatible Bitcoin full node in **Python** for **testnet4**. The forward
native/Core path uses RocksDB-backed operational state plus native crypto; legacy
SQLite scout evidence is historical only.

Contributor-oriented module map and data flows: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status (testnet4)

Current Python readiness is owned by Project imports, not by hand-maintained
Markdown counters. Query Project for current baseline, consensus, Docker, and
benchmark state:

```bash
python3 ../../Project/scripts/report.py --db ../../Project/project.db --section port-baseline-5k
python3 ../../Project/scripts/report.py --db ../../Project/project.db --section consensus-runway
python3 ../../Project/scripts/report.py --db ../../Project/project.db --section benchmark-gates
```

For live local inspection, use:

```bash
pybitnode-status --state-path ./data/chainstate-rocksdb
```

Snapshots and [`docs/BLOCKER_LEDGER.md`](docs/BLOCKER_LEDGER.md) remain
historical evidence, not current mission-control truth.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

## Commands

```bash
# Run node (P2P + optional sync)
pybitnode --datadir ./data

# Sync blocks in batches
pybitnode-sync --datadir ./data --blocks-target 5000 --blocks-max 200

# Rebuild UTXO set from stored blocks
pybitnode-sync --datadir ./data --connect-only --rebuild

# Tracker / progress summary
pybitnode-status --state-path ./data/chainstate-rocksdb

# Native RocksDB binding proof
pybitnode-rocksdb-proof --datadir ./data-python-rocksdb-proof

# Tests
pytest -q
```

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md) for sync/rebuild/snapshot runbooks.

## Layout

```
pybitnode/
  chain/       testnet4 params, genesis
  wire/        message framing, capability registry
  messages/    version, headers, tx, block, addr
  p2p/         peer connections, discovery, manager
  sync/        header + block sync, validation
  consensus/   PoW, merkle, UTXO connect, scripts, secp256k1
  storage/     blk*.dat block files
  chainstate/  canonical native chainstate API
  db/          legacy compatibility namespace for old tracker imports
snapshots/     exported tracker state (committed)
data/          live datadir (gitignored)
```

## Docker

```bash
docker compose -f docker/docker-compose.yml up
docker compose -f docker/docker-compose.yml run --rm --no-deps pybitnode-rocksdb-proof
```

Full replay from an empty native datadir is intentionally out of scope for the
native-break setup work; see
[`docs/NATIVE_REPLAY_HANDOFF.md`](docs/NATIVE_REPLAY_HANDOFF.md) for the next
proof phase boundary.
