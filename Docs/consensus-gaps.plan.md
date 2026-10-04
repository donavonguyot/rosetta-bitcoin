---
name: Zig consensus gaps
overview: Close the two Zig consensus gaps by sharing the existing finality, BIP68, and testnet4 nBits rules with block connect and header validation, then prove them with a must-reject fixture family and a header walk to the local tip.
todos:
  - id: commit-plan
    content: Branch zig/consensus-gaps from local main fec3b72 and commit Docs/consensus-gaps.plan.md
    status: pending
  - id: shared-rules
    content: Add chain_params.zig and consensus_context.zig; point mempool and template at them; add mechanism tests
    status: pending
  - id: connect-finality
    content: Check tx finality and BIP68 in connectDecodedBlock and add the block must-reject fixtures
    status: pending
  - id: header-nbits
    content: Check required nBits and BIP94 timewarp on header ingest, add check-headers, and add the header fixtures
    status: pending
  - id: evidence
    content: Rebuild the fixture package, run check-headers, host gates, and mempool replay, then write evidence and close the ledger
    status: pending
isProject: false
---

# Close Zig finality and nBits gaps

Branch `zig/consensus-gaps` from local `main` at `fec3b72`. That commit already contains `zig/native-chainstate` (`cb7ffb6`) and the rebased `zig/mempool-mining`. `origin/main` does not. Leave the uncommitted rung-0 evidence (`current_evidence.json` and the two host result files) out of these commits.

Commit 0 writes this plan to [Docs/consensus-gaps.plan.md](Docs/consensus-gaps.plan.md) with the same frontmatter as [Docs/mempool-mining-rung0.plan.md](Docs/mempool-mining-rung0.plan.md) (`name`, `overview`, `todos`, `isProject: false`). Zig only. Fixtures are port-agnostic.

## One implementation

New [Nodes/Zig/src/chain_params.zig](Nodes/Zig/src/chain_params.zig) holds testnet4 data, not branches buried in connect:

- `pow_limit_bits = 0x1d00ffff`, spacing `600`, timespan `1_209_600`, interval `2016`, min-difficulty gap `1200`, timewarp `600`
- `bip113_height = 1`, `csv_height = 1`

Python [Nodes/Python/pybitnode/chain/params.py](Nodes/Python/pybitnode/chain/params.py) has magic and genesis only, no deployment heights. The heights above are the testnet4 values this task specifies. The header walk is the check that they do not reject real history. If a stored header fails, stop and ledger the discrepancy; do not read Core to implement, only to resolve that failure.

New [Nodes/Zig/src/consensus_context.zig](Nodes/Zig/src/consensus_context.zig) is the only copy of the rules. Callers:

- [Nodes/Zig/src/mempool.zig](Nodes/Zig/src/mempool.zig) `locktimeUnsatisfied` / `sequenceUnsatisfied` become wrappers. Pool outputs are already stored at `next_height` ([mempool.zig](Nodes/Zig/src/mempool.zig) line 242). Drop the `from_pool => always unsatisfied` shortcut and use the consensus formula. A zero relative lock on a pool output then passes; any nonzero height lock still fails because `coin_height == next_height`. Re-run the rung-0 replay and require the same verdicts.
- [Nodes/Zig/src/template.zig](Nodes/Zig/src/template.zig) `nextBits` and the BIP94 floor in `headerTimeFor` call the same functions. The frozen assembly-byte fixture stays valid because `assemble` is given its bits.
- [Nodes/Zig/src/root.zig](Nodes/Zig/src/root.zig) `connectDecodedBlock` and [Nodes/Zig/src/p2p.zig](Nodes/Zig/src/p2p.zig) `headersThrough`.

`checkProofOfWork` in [block.zig](Nodes/Zig/src/block.zig) stays as it is. Do not change the set-hash fold, codec, stores, or script interpreter.

The existing formulas already match the task, so the shared module keeps them:

- Finality in `locktimeUnsatisfied` is the same predicate as `nLockTime == 0`, all sequences `0xffffffff`, or `nLockTime < height` / `nLockTime < mtp`. Mempool passes `next_height`, which is the block height under consideration.
- BIP68 height `age < masked` is `min_height < h` with `min_height = coin_height + masked - 1`.
- BIP68 time uses `confirmation_mtp`, which [coins_view.zig](Nodes/Zig/src/coins_view.zig) already sets to the MTP of `max(coin_height - 1, 0)`. `age < masked * 512` matches `min_time < mtp` with the `- 1` in the spec.
- `nextBits` already uses `first.nBits` at `h - 2016`, the quarter/4x clamp, the 20-minute exception, and the walk back across `pow_limit` blocks. Height 0 returns `pow_limit` and is not a timewarp check. Compare `prev.time + 1200` in `i64`, not wrapping `u32`.

MTP for a block at `h` is the median of the previous 11 header timestamps, anchored at `h - 1` (`medianTimePast` in the coins view). Fewer headers at the start: sort what exists and take index `count / 2`.

## Check order

In `connectDecodedBlock`, first failure wins:

- coinbase structural rules stay first
- **tx finality on every transaction**, including the coinbase, before inputs are resolved
- per input: duplicate / missing / coinbase maturity, then **BIP68 on non-coinbase version `>= 2`**, then the existing script job
- same-block outputs use `coin_height = h` and `coin_time` = MTP of `h - 1`

Header ingest in `headersThrough`, beside the existing PoW check: structure and prev-hash, **required `nBits`**, PoW, **timewarp on retarget heights**. Do not add a new median-time timestamp rule; that is not one of these gaps. `decodeBlock` keeps its own-bits PoW check. `parseTemplate` / `testBlockValidity` stay the no-PoW connect path.

Reject reasons, mapped from new errors: `tx_not_final`, `sequence_lock_unsatisfied`, `nbits_mismatch`, `timewarp`.

## Fixtures

Family `consensus.context` under [Nodes/Shared/conformance/fixtures/consensus/context/](Nodes/Shared/conformance/fixtures/consensus/context/), with a manifest. That tree is inside the canonical package roots, so the package hash changes. Register the ids in [Project/scripts/build_fixture_package.py](Project/scripts/build_fixture_package.py) `must_reject_inputs` via the new manifest, not by stuffing them into the 45-script corpus.

Block cases are a real testnet4 block already stored under height 5000 in the script corpus. Changing locktime or sequence changes txid and wtxid, so rebuild the merkle root and the coinbase witness commitment. `testblockvalidity` then fails on finality or BIP68 rather than on merkle. Header cases are `(height, time, nBits)` sequences fed to the pure required-bits / timewarp functions.

Each id has a reject case and an unmodified accept twin:

- `consensus.tx_finality_height`, `consensus.tx_finality_mtp`
- `consensus.bip68_height`, `consensus.bip68_time`, `consensus.bip68_same_block`
- `consensus.nbits_min_difficulty_misuse`, `consensus.nbits_retarget_wrong`, `consensus.bip94_first_block_bits`, `consensus.bip94_timewarp`

A new `consensus-context` subcommand runs them. Do not send them through `script-corpus`.

Mechanism tests in [Nodes/Zig/tests/consensus_context.zig](Nodes/Zig/tests/consensus_context.zig), wired like the mempool tests: short MTP, `nLockTime == h - 1` and `== h`, disable bit, version 1 skipped, same-block coin height, retarget clamp at both bounds, min-difficulty walk-back, BIP94 base from `first.nBits`, timewarp at exactly `-600` (valid) and `-601` (invalid).

## Oracles and evidence

`check-headers` walks `headerAt` from genesis through the local tip, at least 155063, on the existing mempool datadir (`~/.rblab/zig/mempool-rung0` or the native copy). It counts heights, retarget boundaries, min-difficulty blocks, and timewarp checks. Seconds, not a resync. Any failure is a wrong rule, not a fixture to weaken.

Then the host 5k, 50k, and 100k gates, ReleaseSafe. Require the same `validated_hash`, UTXO count, and set hash as the current indexed host proofs, including the 100k hash whose prefix is `8d9903` and whose suffix is `fc32`. Record `block_parse_validate` and `connect_total` deltas. Re-run the rung-0 mempool replay after restoring a store to the trace start hash.

Evidence: [Nodes/Shared/conformance/results/zig_consensus_context_host_<date>.json](Nodes/Shared/conformance/results/) schema `port.consensus_context.v1`, with per-fixture results, the `check-headers` counts, gate hashes, timing deltas, and provenance `run_ref=zig-consensus-gaps`, the new `fixture_hash`, `source_commit`, `binary_sha256`. Index claim `consensus_context`. Import. No benchmark fields and no status fields, so Zig port-status stays put.

Ledger: in commit 4, append two closing objects to [Nodes/Zig/docs/blocker_ledger.jsonl](Nodes/Zig/docs/blocker_ledger.jsonl) citing the commit that added finality/BIP68 and the commit that added required `nBits`/BIP94. Do not rewrite the original `consensus_gap` lines.

## Commits

- (0) plan file only
- (1) `chain_params.zig`, `consensus_context.zig`, mempool and template call sites, mechanism tests
- (2) finality and BIP68 in `connectDecodedBlock`, block fixtures, corpus subcommand
- (3) required `nBits` and timewarp in `headersThrough` and `check-headers`, header fixtures, package rebuild
- (4) gates, evidence, provenance, ledger close, import
