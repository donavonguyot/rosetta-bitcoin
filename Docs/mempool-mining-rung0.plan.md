---
name: Mempool mining rung 0
overview: Write the shared mempool and template contracts and a content-hashed trace fixture first, then a Zig layer-1 mempool and template assembly that replay that fixture on both stores. Replay syncs to the trace start height so the live trace is the oracle. Branch from the pushed native-chainstate tip after two consensus-gap ledger lines; the plan file is commit 0.
todos:
  - id: ledger-gaps
    content: On b21f6b5, before the branch, append two consensus_gap lines for nLockTime/BIP68 and nBits/BIP94. Do not implement them in connect.
    status: pending
  - id: commit-plan
    content: Cut zig/mempool-mining from that ledger commit and commit Docs/mempool-mining-rung0.plan.md with no RPC credentials
    status: pending
  - id: contracts
    content: Write MEMPOOL_CONTRACT.md and TEMPLATE_CONTRACT.md with preface, apply order, expected_layer1, BIP94, and the read-forwarding validity wrapper
    status: pending
  - id: capture-fixture
    content: Capture the live trace (pool preface, topo sort, expected_layer1, reorg stop) or, only if Core is unavailable, a synthetic mini-trace
    status: pending
  - id: zig-mempool
    content: Add coins view, mempool, replay that syncs to start_height, mechanism tests, and the mempool gate on both stores
    status: pending
  - id: zig-template
    content: Add template assembly, testblockvalidity, selection, assembly fixture, and the mining gate
    status: pending
isProject: false
---

# Mempool and mining, rung 0

Branch `zig/mempool-mining` from the pushed tip `origin/zig/native-chainstate` (`b21f6b5`), after the pre-branch ledger commit below. The local branch is four unpushed self-hosted commits ahead of that tip; leave them there. If that lane lands first, rebase. Touch [`Nodes/Zig/src/main.zig`](Nodes/Zig/src/main.zig) and [`Nodes/Zig/Makefile`](Nodes/Zig/Makefile) only to add subcommands and targets. New code is new modules. ReleaseSafe for anything measured. Default hash stays `txid64_mix`. No capacity hint. Host only.

Commit 0, before any other rung change, writes this document to [`Docs/mempool-mining-rung0.plan.md`](Docs/mempool-mining-rung0.plan.md) with the same YAML frontmatter the native-chainstate plans use (`name`, `overview`, `todos`, `isProject: false`). Do not copy Reference RPC credentials into that file or any other doc. Ports and the conf path are enough; the secrets stay in [`Nodes/Reference/bitcoin.conf`](Nodes/Reference/bitcoin.conf). Milestones 1–2 are root-owned. Milestones 3–4 are Zig-owned. Do not wait for review after milestone 2; if the fixture shape changes on review, rebase 3–4 onto it.

## Before the branch

Append two objects to [`Nodes/Zig/docs/blocker_ledger.jsonl`](Nodes/Zig/docs/blocker_ledger.jsonl) in a commit whose parent is `b21f6b5`, not the unpushed self-hosted tip. Cut `zig/mempool-mining` from that commit. This commit is not a rung milestone and does not change `connectDecodedBlock` or header validation. Both gaps are must-reject corpus work for the consensus lane. Testnet4 history does not exercise them, which is why a passing sync would not show them. Rung 0 still implements the checks in `mempool.zig` and `template.zig`. That does not close the gaps.

```json
{"kind":"consensus_gap","site":"root.zig connectDecodedBlock","failure":"nLockTime and BIP68 are not checked against block height and MTP","missing_rule":"IsFinalTx and SequenceLocks","fix":"consensus-lane must-reject corpus; not closed by mempool rung 0","follower_notes":"OP_CLTV and OP_CSV only compare the script number to the transaction's own lock_time and sequence. A block connect can accept a transaction that is not final for that block."}
```

```json
{"kind":"consensus_gap","site":"block.zig checkProofOfWork","failure":"header nBits is not checked against the testnet4 retarget rule","missing_rule":"GetNextWorkRequired plus BIP94 timewarp","fix":"consensus-lane must-reject corpus; not closed by template rung 0","follower_notes":"PoW is checked against the compact target stored in the header. The header's nBits is not required to equal the retarget, and the first block of a 2016-period is not checked for the BIP94 timewarp. Verify the rule against Core testnet4 chainparams, not the testnet3 description."}
```

## Stated deviations

- The canonical fixture package ([`Project/scripts/build_fixture_package.py`](Project/scripts/build_fixture_package.py) roots `conformance/fixtures` and `testing/fixtures`) does not gain this trace. A window of up to 200MB would change every port's `fixture_hash`. The trace is a separate content-hashed directory. `provenance.validate` still requires `fixture_hash` to be a retained package pin, so gate provenance keeps that pin and adds `trace_hash`. Extra keys are already preserved.
- [`connectDecodedBlock`](Nodes/Zig/src/root.zig) is not edited in this rung. `nLockTime` and BIP68 against height and MTP are checked in `mempool.zig` for layer 1. The consensus-gap line above is the record that connect still lacks `IsFinalTx` and `SequenceLocks`. `script.zig`, the codec, and `foldSetHash` stay as they are.
- `testblockvalidity` calls the existing `connectDecodedBlock` through a store wrapper. The wrapper forwards every read (`getManyUtxosWithStats`, header reads) to the real store and discards `commitConnectedBlock`. It is not an empty store. No new parameter on connect, and the sync call site in `main.zig` stays. Duplicate-txid and weight rejects are checks in `template.zig` before that call. Connect already returns `DuplicateSpendInBlock` for a repeated outpoint; it does not look at txid equality.
- Zig has PoW checking ([`block.checkProofOfWork`](Nodes/Zig/src/block.zig)) and no retarget. `template.zig` computes testnet4 `nBits` and the BIP94 timewarp floor itself, after reading Core 28.2 testnet4 chainparams rather than a testnet3 writeup. `decodeBlock` is not given a skip-PoW flag. The template parser checks merkle root and witness commitment and does not call `checkProofOfWork`. The second consensus-gap line is the record that header validation still does not enforce that `nBits`.
- Synthetic is only the fallback when Reference Core is down, still in IBD, or refuses a v1 handshake (`reference_capture_unavailable`). A store that is below `start_height` is not a reason to go synthetic. Replay runs the existing `sync --target <start_height>` against Reference, asserts the tip hash equals `start_hash`, then applies events. Expected cost if the self-hosted native datadir is present: one sync from about 138k to the capture tip, near 155k. The post-100k lane already showed that range is feasible. Both stores sync. A tip-hash mismatch fails the gate.
- Do not implement BIP324. Reference is Core 28.2, P2P `127.0.0.1:48333`, RPC `127.0.0.1:48332`, magic `1c163f28`. Credentials stay in the Reference conf.

## Milestone 1 — contracts

[`Nodes/Shared/mempool/MEMPOOL_CONTRACT.md`](Nodes/Shared/mempool/MEMPOOL_CONTRACT.md) and [`Nodes/Shared/mining/TEMPLATE_CONTRACT.md`](Nodes/Shared/mining/TEMPLATE_CONTRACT.md), in the style of [`Nodes/Shared/storage/STORAGE_GATE.md`](Nodes/Shared/storage/STORAGE_GATE.md).

Layer 1 is strict and cross-port. Layer 2 (standardness, fees, limits, RBF, relay) is `policy@core-<version>` and is not a verdict. Core is a byte source and a policy reference. Core 28 defaults to full RBF, so a relayed transaction is not a layer-1 accept.

Mempool set hash reuses [`foldSetHash`](Nodes/Zig/src/store.zig): XOR of `SHA256(wtxid)` with an empty value. Wtxid is internal byte order, the `doubleSha256` output, not the display reversal. XOR is its own inverse, so accept folds in and eviction folds out. Reported after every applied event.

Layer-1 check order, first failure wins:

- `coinbase` — null prevout (`index == 0xffffffff` and a zero hash), same test as [`Transaction.isCoinbase`](Nodes/Zig/src/tx.zig)
- `input_spent_in_pool` — outpoint already spent by a pool transaction
- `input_spent_on_chain` — outpoint was removed by a connected block in this replay
- `missing_input` — not in the store and not an unspent pool output
- `locktime_unsatisfied` — not final for `next_height = tip + 1` and `mtp` = median of the last 11 header timestamps ending at the tip (fewer if the tip is shorter). Final if every sequence is `0xffffffff`, or `lock_time == 0`, or (`lock_time < 500000000` and `lock_time < next_height`), or (`lock_time >= 500000000` and `lock_time < mtp`)
- `sequence_unsatisfied` — BIP68 against that same next height and MTP, using the spent output's height and the MTP of the block that created it. Version below 2, or the disable bit, skips the input
- `script_failed` — [`script.verifyInput`](Nodes/Zig/src/script.zig) returned any error. The existing verifier is the next-block flags; there is no flag bitmask to thread through

Apply order is parent-first, not capture order. Each tx annotation carries `capture_seq` (omitted for the preface) and `apply_seq`. On-disk event order is `apply_seq`. Within the preface, and within each run of tx events between blocks, stable topological sort by in-trace input dependencies: if B spends an output created by A, A is applied first. Tie-break keeps the earlier `capture_seq` (preface tie-break is lexicographic wtxid). Block events stay in capture order and are not sorted through the txs. A trace whose blocks do not form a single chain from `start_hash` is not a fixture.

`expected_layer1` is computed on apply order, not on Core's relay decision. It is `input_spent_in_pool` when any input outpoint is already spent by an earlier applied tx that is still unconfirmed, otherwise `accepted`. The oracle is: the port's verdict equals `expected_layer1`. A child announced before its parent is reordered, not rejected. A replacement Core relays under full RBF is a real layer-1 reject.

Replay: sync the store to `start_height`, require tip hash `start_hash`, apply the preface, then apply events. After each applied event the port reports the set hash. After a tx event it also reports the verdict and the reason enum. A block event connects the block with the port's own connect, then evicts pool txs whose txid is in the block, txs that spend an outpoint the block spends, and their in-pool descendants.

Mutation corpus, seeded, not taken from Core rejects. Seed `0x524F5345545441`, xorshift64* (`x ^= x >> 12; x ^= x << 25; x ^= x >> 27; result = x * 0x2545F4914F6CDD1D`). Per class, shuffle eligible trace txs and keep 32. Classes and the expected reason:

- flip the last byte of the last signature item — `script_failed`. Eligible only if the tx has a signature: a witness item or scriptSig push that is Schnorr (64 or 65 bytes) or ECDSA (at least 9 bytes, DER-shaped). Walk items from the end and flip the last byte of the last match. A tx with no such item is skipped
- retarget one input to an outpoint already spent by an earlier pool tx — `input_spent_in_pool`
- retarget one input to an outpoint spent by a block already applied — `input_spent_on_chain`
- set `lock_time` to `next_height + 1`; if every sequence is final, set input 0 sequence to `0xfffffffe` so the locktime is enforced — `locktime_unsatisfied`
- one null input, outputs kept — `coinbase`

Trace directory `Nodes/Shared/fixtures/mempool/trace-<sha256>/`. The digest is SHA-256 of a canonical tar of that directory only (sorted paths, mode 0644, zero mtime, uid, gid, empty owner names), the same canonicalization as `write_tar`. Files:

- `manifest.json` — schema `mempool.trace.v1`: chain, core version, `policy` string `policy@core-<version>` marked as policy, window start/end and stop reason `time|bytes|reorg`, `start_height`, `start_hash`, preface count, event/tx/block counts, raw byte count, mutation seed, set-hash id `xor-sha256-wtxid-v1`. A `reorg` stop does not produce a directory
- `events.bin` — apply order, little-endian frames: `u32 apply_seq`, `u64 capture_unix_ms`, `u8 kind` (1 tx, 2 block), `u32 payload_len`, raw tx or raw block. Preface txs occupy the first `apply_seq` values
- `annotations.jsonl` — one object per event. Tx: `capture_seq` or null, `apply_seq`, txid, wtxid, `expected_layer1` (`accepted` or `input_spent_in_pool`), and for live arrivals the Core `getmempoolentry` fee, vsize, and ancestor count. Preface rows are marked `preface: true`. Block: hash, tx count, prev hash. Fee fields are diagnostic
- `boundaries.jsonl` — one object per block: height, hash, `core_set_hash` (the same XOR fold over `getrawmempool` wtxids after Core processes the block), pool count, and the last `getblocktemplate` captured before the block (poll every 10s): total fees, tx count, txid list. Absent GBT is null. With the preface in the pool, a boundary difference against the port is policy, and the count is worth recording
- `mutations.json` — schema `mempool.mutations.v1`: seed, algorithm, and per mutation the class, source `apply_seq`, raw bytes, and expected reason

Index: [`Nodes/Shared/fixtures/mempool/index.json`](Nodes/Shared/fixtures/mempool/index.json), schema `mempool.trace_index.v1`, one row per trace (hash, path, chain, core version, window, counts, policy). Not an entry in [`fixture_package.json`](Nodes/Shared/conformance/fixture_package.json).

Template assembly, byte-exact across ports for a fixed ordered tx list and fixed coinbase parameters:

- coinbase scriptSig is the BIP34 height push plus the tag `RosettaBitcoin/zig`
- output 0 pays `subsidy + fees` to script `0x51`. Subsidy is `50 * 100000000 >> (height / 210000)`
- output 1 is value 0 and the BIP141 witness commitment. Reserved value is 32 zero bytes. Coinbase wtxid in the witness merkle is 32 zero bytes. Commitment check already exists as [`validateWitnessCommitment`](Nodes/Zig/src/block.zig)
- header version `0x20000000`, prev hash the tip, merkle root from [`merkleRoot`](Nodes/Zig/src/block.zig), nonce 0
- time is `max(mtp + 1, now)` on the live path, then raised to satisfy BIP94 when the next height is a multiple of 2016: `time >= previous_header_time - 600`. Read the exact predicate from Core 28.2 testnet4 (`enforce_BIP94`) before freezing the sentence in the contract
- `nBits` from the port, again from those chainparams: pow limit compact `0x1d00ffff` (genesis bits in [`Nodes/Python/pybitnode/chain/genesis.py`](Nodes/Python/pybitnode/chain/genesis.py)), 2016-block retarget, timespan clamped to a quarter and 4x, the 20-minute exception, and the walk back across exception blocks. Do not transcribe the testnet3 rule in place of BIP94
- the byte-exact fixture freezes time, bits, prev hash, and the tx list. Live `build-template` is allowed to use the clock

`testblockvalidity` is that connect without PoW and without a state write. The read-forwarding wrapper above is part of the contract, so a follower does not substitute a null store. Required of any port that claims assembly.

Selection: ancestor package feerate. Package is the tx plus in-pool ancestors. Compare `fee_sum / weight_sum` by cross-multiply, no floats. Repeatedly take the highest package that fits the remaining `4_000_000` weight and `80_000` sigop cost. Tie-break is the lexicographic minimum child wtxid. Block sigop cost is the BIP141 scaled counter, not the tapscript validation budget in `script.zig`. Fee ratio versus Core's recorded GBT fees at the same boundary is a diagnostic, not pass/fail.

Fixture IDs: `mempool.trace_replay_set_hash`, `mempool.layer1_verdicts`, `mempool.mutation_rejects`, `mempool.block_connect_eviction`, `mining.assembly_bytes`, `mining.testblockvalidity`, `mining.selection_fee_ratio`.

Out of rung 0: policy, relay, RBF implementation, orphan pool, PoW search, persistence, `getblocktemplate` proposal mode as an oracle, fee estimation, and the connect/header fixes for the two consensus gaps.

## Milestone 2 — capture

[`Project/scripts/capture_mempool_trace.py`](Project/scripts/capture_mempool_trace.py). P2P v1 peer so `tx` and `block` arrive in order (version, verack, sendheaders, then inv/getdata). No feefilter, mempool, or sendcmpct. RPC only for annotations and the preface. Stop at one hour or 200MB of raw payload bytes, not counting the preface.

At start, after `start_height` and `start_hash` are recorded, snapshot `getrawmempool` and `getrawtransaction` for each id. Emit those as preface tx events, topologically sorted, before `capture_seq` 1. Then the live window. Assign `expected_layer1` on the resulting apply order.

Each block must extend the chain: the first block's prev hash is `start_hash`, and every later block's prev hash is the previous block's hash, height increasing by 1. Anything else is a reorg or an orphan. Stop, do not write a trace directory, and ledger `capture_reorg`. That window is not a fixture. Do not substitute the synthetic trace for a reorg.

Write the directory, compute the canonical-tar hash, rename to `trace-<hash>/`, append the index row, generate the mutation corpus with the contract seed.

Preflight `getblockchaininfo`: `initialblockdownload` false and headers equal to blocks, otherwise ledger `reference_capture_unavailable` and do not start the hour. Synthetic fallback, same on-disk shape, `fixture: synthetic`, only in that case: pull raw blocks for a short range inside height 0..5000 via RPC `getblock` (verbosity 0) or, if RPC is down, from a local datadir that already has them. Those blocks are the preface that lets replay start from an empty store. Then emit non-coinbase transactions from the next few blocks as tx events with `expected_layer1: accepted`, then the blocks that contain them. Mutations use the same generator. Mark every later gate line `fixture:synthetic` until a real capture exists.

Commit the fixture, the index, and the tool. This is the review checkpoint.

## Milestone 3 — Zig mempool

[`Nodes/Zig/src/coins_view.zig`](Nodes/Zig/src/coins_view.zig): store underneath, pool outputs overlaid, in-pool spends marked, on-chain spends recorded when a block connects. Read-only. Header-by-height for MTP uses the existing header keys (`encodeHeaderKey` on RocksDB, the native header extent). No fold or commit change.

[`Nodes/Zig/src/mempool.zig`](Nodes/Zig/src/mempool.zig): wtxid to tx bytes, fee, vsize, ancestors, arrival `apply_seq`. Set hash updated on accept and on eviction. `accept` runs the check order above. `onBlockConnected` drops confirmed txs, conflicts, and descendants. `restoreAfterDisconnect` returns `error.DisconnectReplayNotImplemented` and is never quiet. One ledger line at commit time: re-add on disconnect is pending tip work. That line is separate from the two `consensus_gap` lines.

Subcommand `mempool-replay --trace <dir> --store=native|rocksdb`. It runs `sync --target <start_height>` for that store against the local Reference peer, reads the tip, and requires the hash to equal `start_hash` before the preface. Then one stdout line per block boundary: set hash, pool size, verdict counts, and the Core boundary hash beside it. A final gate line. Both stores. A tip mismatch is a failed gate, not a synthetic fallback.

Mechanism tests in [`Nodes/Zig/tests/mempool.zig`](Nodes/Zig/tests/mempool.zig), wired from [`Nodes/Zig/build.zig`](Nodes/Zig/build.zig) the way `native_store` tests are: fold in and out, in-pool spend accepted, in-pool double spend rejected, on-chain double spend rejected, child-before-parent in capture order applied parent-first, replacement marked `input_spent_in_pool`, each mutation class rejected with the expected reason, block connect evicts confirmed and conflicting txs. `zig build test` stays the fast path.

Oracle: every tx verdict equals its `expected_layer1`; every mutation is rejected with the recorded reason; set hash after each block matches across the two stores. Core's boundary hash is printed beside the port hash. Record the mismatch count. Do not chase it. With the preface applied, a mismatch is a policy difference rather than an empty-pool artifact.

## Milestone 4 — Zig templates

[`Nodes/Zig/src/template.zig`](Nodes/Zig/src/template.zig): coinbase, merkle root, witness commitment, header, `nBits`, BIP94 time floor, selection.

Subcommand `testblockvalidity` reads a raw block, checks duplicate txids and weight, then runs `connectDecodedBlock` on the read-forwarding wrapper. Subcommand `build-template --trace <dir>` uses the same sync-then-replay pool state. At each block boundary it builds a template and prints validity, weight, fee total, and fee ratio against the boundary's GBT fees. Median ratio on the final line.

Mechanism tests: byte-exact assembly for a frozen tx list and coinbase params; the expected bytes land at `Nodes/Shared/fixtures/mining/assembly_bytes_v1.bin` and a row in `Nodes/Shared/fixtures/mining/index.json` (also outside the canonical package). Witness commitment present and matching `validateWitnessCommitment`. `testblockvalidity` rejects a duplicate txid and a block over `4_000_000` weight. One test shows the wrapper still returns a store UTXO for a prevout the template spends.

Oracle: every template from the pool passes the port's own `testblockvalidity`. Fee ratio per boundary, plus the median. Not pass/fail.

Export `validateWitnessCommitment` (visibility only) so the template test can call it. No change to its body.

## Evidence

Two files, host, date from `date +%F`:

- `Nodes/Shared/conformance/results/zig_mempool_rung0_host_<date>.json` — schema `port.mempool.rung0.v1`
- `Nodes/Shared/conformance/results/zig_mining_rung0_host_<date>.json` — schema `port.mining.rung0.v1`

Each is one object. `results` lists the fixture IDs above with `passed` or `skipped`. `fixture` is `live` or `synthetic`. Provenance: `run_ref` `zig-mempool-mining-rung0`, `fixture_hash` the canonical package pin, `trace_hash`, `source_commit`, `binary_sha256`, stamped with [`Project/scripts/provenance.py`](Project/scripts/provenance.py) on a clean tree.

Omit `benchmark_gate`, `benchmark_kind`, `benchmark_lane`, `benchmark_contract_version`, `target_height`, `target_label`, `validated_height`, `header_height`, `sync_status`, and `chainstate_backend`, so [`import_benchmark_rows`](Project/scripts/import_all.py) and [`import_status_snapshot`](Project/scripts/import_all.py) do not open a benchmark row or move Zig status. Index both under claims `mempool` and `mining` in [`Nodes/Shared/conformance/current_evidence.json`](Nodes/Shared/conformance/current_evidence.json). Import the stored artifacts only. Confirm the Zig port-status row is unchanged.

## Commits

- (pre) two `consensus_gap` lines, parent `b21f6b5`, then cut the branch
- (0) plan file only, no credentials
- (1) the two contracts
- (2) capture tool, trace, mutation corpus, index
- (3) coins view, mempool, replay, tests, mempool gate
- (4) template, testblockvalidity, selection, tests, mining gate

Further blockers are one JSON object each in [`Nodes/Zig/docs/blocker_ledger.jsonl`](Nodes/Zig/docs/blocker_ledger.jsonl). No markdown reports beyond the contracts and this plan.
