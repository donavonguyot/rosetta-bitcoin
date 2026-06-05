# Elixir (exbitnode)

Supervised Bitcoin **testnet4** follower on the BEAM/OTP. Elixir is the exotic
follower in the Nodes fleet: peer sessions, sync workers, and chainstate writes are
designed for fault isolation and restartable long-running node behavior.

**Binary gate:** from empty local state, connect to testnet4, independently validate
every stored connected block, reach/maintain tip. Header-only sync does not pass.

## Role in the fleet

| Node | Role |
|------|------|
| Python / Java | Provenance sources for Shared rule cards and fixtures |
| TypeScript / CSharp | Fast managed followers |
| **Elixir** | Supervised follower — OTP process boundaries, honest blockers |

Use the Shared consensus rule ledger and script corpus as the consensus work
queue. Elixir must not treat Python, Java, or local Core as validation oracles.
Known blocker heights are already corpus fixtures; baseline work should prove the
corpus before live-sync discovery.

## Prerequisites

- Elixir 1.16+ / OTP 26+
- Local Bitcoin Core on testnet4 (`127.0.0.1:48333`) for development byte source

## Commands

```bash
cd ElixirNode

# Fetch deps, compile, run tests
make test

# Read-only JSON status (runtime, heights, blockers, lock)
make status

# Sync headers from local Core (default peer 127.0.0.1:48333)
make sync-local

# Tune header download
HEADERS_MAX=5000 HEADER_BATCHES_MAX=20 make sync-local

# Tune block download (after headers)
BLOCKS_MAX=128 make sync-local
HEADERS_MAX=0 BLOCKS_MAX=1000 make sync-local   # blocks-only catch-up
SKIP_BLOCKS=1 make sync-local   # headers only
```

Datadir defaults to `./data-elixir` (gitignored). One writer at a time — a datadir
lock prevents concurrent sync processes.

## Docker proofs

```bash
make docker-config
make docker-proof-local
make docker-proof-10k
make docker-proof-50k 2>&1 | python3 ../../Project/scripts/monitor_benchmark_telemetry.py
```

`make docker-proof-local`, `make docker-proof-10k`, and `make docker-proof-50k`
are local Reference P2P proofs with fresh Docker volumes, RocksDB, native
secp256k1, WAL enabled, and parallel script verification. The 50k proof uses a
one-shot supervisor so long runs emit both `AGENT_LOOP_TICK_chatreport` and
`benchmark.telemetry_tick` progress lines.

## Status fields

`make status` reports:

- `runtime_status` — idle, syncing, blocked, failed
- `header_height` / `validated_height`
- `block_count` / `utxo_count`
- `current_blocker` / `last_error`
- `recommendation` — leave_running, checkpoint, investigate, rebuild, run_sync_local

## M1 scope (complete)

- Mix project + ExUnit tests
- Bitcoin wire framing and checksums
- version/verack handshake with deferred post-verack (`sendheaders` only)
- getheaders/headers download and parsing
- Header validation: prev-hash linkage, block hash, PoW target
- RocksDB-backed native chainstate persistence
- Datadir lock + JSON status

## M2 scope (complete)

- getdata/block download from local Core
- Raw block storage (`data-elixir/blocks/blk*.dat`)
- Block connect: merkle root, coinbase UTXO create, spend validation, undo rows
- Script verify: P2PK, P2PKH, P2WPKH, P2TR key-path (honest stop on P2WSH/P2SH/P2TR script-path/unknown)
- `make sync-local` runs headers then blocks (`BLOCKS_MAX`, `SKIP_BLOCKS`)
- `make status` reports `validated_height`, `block_count`, `utxo_count`, blockers

## M3 scope (complete)

- Block sync past coinbase maturity through height **2539** (no consensus blocker yet)
- Cleared height **739** P2WPKH spend (fixture + regression test)
- Fixes: `hash160` argument order, interpreter stack pop-from-top, `ensure_genesis` sync_state regression
- `Task.Supervisor` for isolated sync worker tasks (`Exbitnode.Sync.Runner`)

## M4 scope (complete)

- **Reorg disconnect:** `BlockConnector.disconnect/3` replays `utxo_undo` (with `utxo_height`) and rewinds tip
- **OTP:** `PeerServer` under `PeerSupervisor` (temporary child); `Sync.Worker` GenServer serializes `sync-local`
- Block sync through height **3411** on local Core (`HEADERS_MAX=0 BLOCKS_MAX=1000`); no consensus blocker yet

## M5 scope (in progress)

- **Peer reconnect:** `BlockSync` retries block download on transport errors (`:closed`, timeout, etc.) with fresh TCP handshake
- **P2TR key-path:** BIP341 TapSchnorr sighash + BIP340 Schnorr verification; fixture at block **6975**
- Block sync continuing toward **6975** (`HEADERS_MAX=0 BLOCKS_MAX=1000`)

```bash
HEADERS_MAX=0 BLOCKS_MAX=1000 make sync-local
```

## M6 next

- Continue sync past P2TR toward **P2WSH/multisig ~25207+** and nested segwit **~27903**
- P2TR script-path (BIP342 tapscript subset)
- Multi-block reorg / header rewind orchestration

## Docs

- [docs/BLOCKER_LEDGER.md](docs/BLOCKER_LEDGER.md) — sync and consensus blockers

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `DATA_DIR` | `./data-elixir` | Datadir + native chainstate |
| `PEERS` | `127.0.0.1:48333` | Comma-separated host:port |
| `CHAIN` | `testnet4` | Chain name |
| `CHAINSTATE_BACKEND` | `rocksdb` | Native chainstate backend |
| `SECP256K1_BACKEND` | `pure_elixir` | `pure_elixir` or `native` backend selector |
| `HEADERS_MAX` | `2000` | Max headers per sync run |
| `HEADER_BATCHES_MAX` | `50` | Max getheaders batches |
| `BLOCKS_MAX` | `128` | Max blocks to connect per sync run |
| `SKIP_BLOCKS` | unset | Set to `1` to skip block download/connect |
