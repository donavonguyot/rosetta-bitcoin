---
name: Parent link check
overview: Reject a block whose prev_hash is not the store tip before any other connect validation, and make check-headers report broken header links. Preserve the testnet4 155428 fork as a fixture before Core drops the loser.
todos:
  - id: commit-plan
    content: Branch zig/parent-link from main and commit this plan only
    status: pending
  - id: fixture
    content: Store the fetched 155427, both 155428s, 155429, and 155448 under Nodes/Shared/fixtures/consensus/reorg_155428 and re-pin the fixture package
    status: pending
  - id: connect-check
    content: requireParentLink before any other connect validation and before PoW on the sync path; unit-test a synthetic two-block chain
    status: pending
  - id: check-headers
    content: Report link_breaks for the validated extent; triage store has one break at 155429, RocksDB tip has none
    status: pending
  - id: evidence
    content: Host evidence, close the diagnostic half of reorg_required, leave the reorg open on consensus.reorg_155428, merge and push
    status: pending
isProject: false
---

# Parent link before any other connect check

Branch `zig/parent-link` from `main` at `592afcc`. The mempool-stimulus working tree stays on `zig/mempool-stimulus`. This plan is commit 0. No RPC credentials.

## What broke

A native store syncing live committed the losing block at height 155428 (1 tx, `000000007e9f81c1562ff674f264ecca2bcf74d9b1298d08d20ef3e60c3a1245`) and then connected 155429–155447. Those headers' `prev_hash` is the winning 155428 (`000000007d2588ec9234ed9be196acc323fe454aa8e48c3217f40d1ce286498d`, 13 txs). `connectDecodedBlock` never compared `prev_hash` to the store tip. The tip hash at 155447 equals Core's. The chainstate does not. `check-headers` walked nBits and timewarp and did not report the broken link at 155429.

Disconnect stays the loud stub. This change does not perform the reorg. It stops a later block from being applied on top of the wrong parent.

## Connect

`requireParentLink` in `connect.zig` is the first check in `connectDecodedBlock`, before coinbase structure, finality, or scripts. `prev_hash` must equal `store.tipHash()`. An empty store (no tip) may connect height 0 only. Any other miss returns `error.ParentMismatch` after a payload with the height and both display hashes.

Sync calls that check on the raw header before `decodeBlock`, so the parent is judged before proof of work. `decodeBlock` then still checks the same tip, not the peer header array. `recordBlock` may store a competing block. Connect may not apply it.

The documented connect order in the `connect.zig` header puts the parent link first, before PoW.

The unit test is a synthetic two-block chain on `MemoryStore`: tip is block A, block B's prev is not A, and the no-PoW connect path returns `ParentMismatch`. A matching prev passes the parent check and fails later on an empty transaction list. Consensus-context fixtures set the memory-store tip from the header at `height - 1` so finality and BIP68 still run.

## check-headers

For every height `1..tip` in the validated extent, compare the header's `prev_hash` to the double-SHA256 of the previous stored header. Each break is `{height, stored_prev, expected_prev}` in display order. The JSON gains `link_breaks`. A non-empty list is `passed: false` and `error.ParentLinkBreak`.

On `~/.rblab/zig/triage-155447-native` that is one break, at 155429. On the RocksDB store whose tip is Core's 155448, there are none. Headers recorded past the validated tip are outside this extent, so the duplicate 155449 slot is not a second break.

## Fixture

Raw blocks were fetched from Reference Core 28.2 while it still served the loser: 155427, both 155428s, 155429, and 155448. They live in `Nodes/Shared/fixtures/consensus/reorg_155428/` with `manifest.json` (heights, hashes, tx counts, common parent, winner, the three 155448 outpoints that spend winner outputs, Core version, fetch time, and the 155448 set hash).

`build_fixture_package.py` includes that directory when it is present and lists `consensus.parent_link_reject` in `must_reject_inputs`. Re-pin. The package roots stay `conformance/fixtures` and `testing/fixtures` so the package test's temporary tree still builds.

- `consensus.parent_link_reject` — 155429 offered through the no-PoW path (`testblockvalidity`) to the triage copy, whose tip is not that block's parent, returns `ParentMismatch`. A store built from the first 155428 corpus blocks is not available; the unit test is the synthetic chain.
- `consensus.reorg_155428` — acceptance fixture for the later disconnect work. The expected set hash is the RocksDB chainstate after it connected Core's block 155448.

## Oracles and evidence

`zig build test` with `-Dstore=both`, `rocksdb`, and `native`. The 5k native shadow set hash stays the indexed host value. `check-headers` is the two results above. The parent-link gate is `testblockvalidity` of 155429 on the triage copy.

A new native store is synced to the Core tip on the winning chain. `check-headers` reports zero breaks. That datadir is the stimulus seed. The forked `trace-seed-work` store is not modified.

Evidence is `Nodes/Shared/conformance/results/zig_parent_link_host_<date>.json`, category `consensus_context`, plus a `current_evidence.json` row. The ledger closes the diagnostic half of `reorg_required` on this commit and leaves the reorg itself open, pointing at `consensus.reorg_155428`. Then merge to `main` and push.
