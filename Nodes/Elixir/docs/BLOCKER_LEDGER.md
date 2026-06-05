# ElixirNode blocker ledger

Handoff notes for exbitnode. Current consensus runway truth comes from
Project plus the Shared consensus rule ledger and script corpus; historical
Python notes are provenance only.

## Last recorded evidence

```bash
cd ElixirNode
make status
```

## M1 — header sync from local Core

| Field | Value |
|-------|-------|
| milestone | M1 header sync |
| peer | `127.0.0.1:48333` (local Bitcoin Core testnet4) |
| scope | version/verack, sendheaders, getheaders/headers, header validation, early persistence scaffolding; current native path uses RocksDB chainstate |
| validated_height | `-1` at M1 completion (blocks not connected yet) |
| missing_rule | `block_connect_not_implemented` |
| follower_notes | Resolved in M2 |

## M2 — block download and connect

| Field | Value |
|-------|-------|
| milestone | M2 block sync + connect |
| peer | `127.0.0.1:48333` |
| scope | getdata/block, merkle validation, coinbase UTXO create, spend-path script verify (P2PK/P2PKH/P2WPKH), undo rows, honest blockers |
| header_height | `136422` (after headers_current run) |
| validated_height | `127` (128 blocks connected: genesis through height 127) |
| block_count | `128` |
| utxo_count | `255` |
| sync_status | `blocks_syncing` |
| missing_rule | none hit in first 128 blocks |
| python_fix | P2PK/P2PKH/P2WPKH implemented per C# follower shape |
| test_fixture | synthetic genesis coinbase in `test/exbitnode_test.exs`; height 739 P2WPKH is now a Shared corpus fixture |
| follower_notes | Coinbase-only / immature-coinbase path through height 127; known spend-path rules must be proved through the Shared corpus rather than rediscovered by live sync |

## M3 — coinbase maturity through P2WPKH (2026-05-25)

| Field | Value |
|-------|-------|
| milestone | M3 block sync past coinbase maturity + P2WPKH |
| peer | `127.0.0.1:48333` |
| starting validated_height | `127` |
| ending validated_height | `2539` (2540 blocks connected: genesis through height 2539) |
| starting utxo_count | `255` |
| ending utxo_count | `4545` |
| header_height | `136426` |
| sync_status | `blocks_syncing` |
| missing_rule | none through 2539 |
| python_fix | Fixed `CryptoUtil.hash160/1` pipe argument order; fixed interpreter stack pop-from-top; fixed `ensure_genesis` sync_state reset regression |
| test_fixture | `test/fixtures/block739_tx.hex` + `ScriptVerifyTest.real testnet4 block739 P2WPKH input0 accepted` |
| follower_notes | Height **739** P2WPKH spend connects after stack/hash160 fixes. Undo rows written on external spends; **reorg disconnect not implemented** (M4). `Task.Supervisor` added for isolated sync tasks. |

## Cleared: height 739 — P2WPKH spend (2026-05-25)

| Field | Value |
|-------|-------|
| height | 739 |
| block_hash | `000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32` |
| txid | `475ff67b2f2631c6b443635951d81127dcf21898f697d5f7c31e88df836ee756` |
| input_index | 0 |
| spent_script_pubkey | `0014a54e2a1ec06389203887661535ed118b7d053889` |
| failure (was) | `script verification failed for input 0` (`hash160` badarg + stack pop-from-bottom) |
| missing_rule (was) | `script_interpreter_bug` (not a missing template) |
| python_fix | Same P2WPKH path as Python/C#; bugs were Elixir-specific |
| test_fixture | `test/fixtures/block739_tx.hex` |
| follower_notes | Resume sync passed 739; continued through **2539** with no new blocker |

## M5 — peer reconnect + P2TR key-path (2026-05-25)

| Field | Value |
|-------|-------|
| milestone | M5 peer reconnect + P2TR key-path |
| peer | `127.0.0.1:48333` |
| starting validated_height | `3411` |
| ending validated_height | in progress (see `make status`) |
| starting utxo_count | `6171` |
| missing_rule | none through first M5 batch at **4411** |
| python_fix | P2TR key-path from Python `test_real_testnet4_block6975_taproot_keypath_accepted` |
| test_fixture | `test/fixtures/block6975_tx.hex` + `ScriptVerifyTest.real testnet4 block6975 P2TR key-path input0 accepted` |
| follower_notes | `BlockSync` reconnects on `:closed`/transport errors (up to 5 retries per block request). BIP341 TapSchnorr sighash + BIP340 Schnorr verify for key-path only; script-path returns false in this historical state. Known later templates now live in the Shared corpus/rule ledger. |

## Cleared: height 6975 — P2TR key-path (fixture)

| Field | Value |
|-------|-------|
| height | 6975 |
| txid | `12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62` |
| input_index | 0 |
| spent_script_pubkey | `512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c` |
| missing_rule (was) | `script_interpreter_not_implemented` |
| python_fix | Schnorr + TapSighash key-path per Python `dd65c78` |
| test_fixture | `test/fixtures/block6975_tx.hex` |
| follower_notes | Live sync pending past height 4411; fixture regression passes |

## Historical next-blocker notes (M6+)

These are historical planning notes. Use the Shared corpus/rule ledger and
Project runway for current work.

| Height (historical trail) | Template | Notes |
|----------------------|----------|-------|
| 6975 | P2TR key-path | First Taproot spend |
| 25207+ | P2WSH / multisig / CLTV / CSV | Now covered by Shared corpus/rule-ledger evidence |
| 27903 | P2SH→P2WPKH nested | Nested segwit |

After corpus proof is clean, continue staged sync and record any genuinely new
`ValidationBlocker` stop beyond the imported rule runway.

## M4 — reorg disconnect + OTP peer supervision (2026-05-25)

| Field | Value |
|-------|-------|
| milestone | M4 reorg/undo + supervised peer/sync |
| peer | `127.0.0.1:48333` |
| starting validated_height | `2539` |
| ending validated_height | `3411` (after partial `BLOCKS_MAX=1000` run; peer closed mid-batch) |
| starting utxo_count | `4545` |
| ending utxo_count | `6171` |
| header_height | `136426` |
| sync_status | `headers_current` (last run ended `error` on peer `:closed`) |
| missing_rule | none through **3411** |
| python_fix | n/a |
| test_fixture | synthetic disconnect/reconnect in `test/exbitnode_test.exs` |
| follower_notes | `BlockConnector.disconnect/3` replays `utxo_undo` with `utxo_height`. `PeerServer` + `PeerSupervisor` isolate TCP; `Sync.Worker` GenServer serializes sync tasks. Undo rows written before M4 lack `utxo_height` (default 0) — reconnect chain if disconnecting pre-migration blocks. Next consensus stop still expected **P2TR ~6975**. |

## Cleared: reorg disconnect (M4)

| Field | Value |
|-------|-------|
| height | any connected tip ≥ 1 |
| failure (was) | `reorg disconnect not implemented` |
| missing_rule (was) | `block_disconnect_not_implemented` |
| test_fixture | `disconnect rewinds tip`, `disconnect restores externally spent utxo and reconnect block`, `take_utxo_undo returns and clears journal rows` |
| follower_notes | Mirrors Python/TS `disconnect_block` flow |

## Reorg / undo (M4+)

- Connect records external prevout spends in `utxo_undo` (includes `utxo_height`).
- Disconnect at tip: `take_utxo_undo` → delete outputs created at height → restore prevouts → rewind `validated_tip`.
- **Not implemented:** multi-block reorg orchestration / header chain rewind (single-height disconnect only).

## Template

```text
height:
block_hash:
txid:
input_index:
spent_script_pubkey:
failure:
missing_rule:
python_fix:
test_fixture:
follower_notes:
```
