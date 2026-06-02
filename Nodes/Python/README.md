# pybitnode

Binary-compatible Bitcoin full node in **Python** for **testnet4**. Stdlib + [sqlite-utils](https://sqlite-utils.datasette.io/) only — no bitcoin libraries.

Contributor-oriented module map and data flows: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status (testnet4)

| Metric | Value |
|--------|-------|
| Headers synced | ~136k |
| Blocks validated | live: `pybitnode-db --db ./data/pybitnode.db` (snapshots may lag) |
| Wire capabilities | 34/43 required (79%) |
| Checkpoints passing | 7/9 |

Phases 0–1 complete; block download and consensus validation in progress. See [`snapshots/`](snapshots/) for exported checkpoints and [`docs/BLOCKER_LEDGER.md`](docs/BLOCKER_LEDGER.md) for cleared consensus stalls.

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
pybitnode-db --db ./data/pybitnode.db

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
  db/          SQLite schema + tracker
snapshots/     exported tracker state (committed)
data/          live datadir (gitignored)
```

## Docker

```bash
docker compose -f docker/docker-compose.yml up
```
