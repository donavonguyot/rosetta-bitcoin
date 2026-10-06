# Doc standard plan

Docs only. No consensus, store, or CLI behavior change. `zig build test`
stays 56/56 for `-Dstore=both`, `rocksdb`, and `native`. Identity oracles:
`--build-info` still names the lane, store, and source commit; the
native-storage-proof set hash stays put; one 5k shadow keeps set hash
`e8a9c06f542eee0672539c72fbcb498cb32e1398a6b5eab05e2b240f4ad07400`.
The binary hash may change. Doc comments are not a behavior change.

## Read before any comment

`docs/blocker_ledger.jsonl`. Campaign JSON under
`Nodes/Shared/conformance/results/` for the native store (hash mix, commit,
utxo load, 100k parity, disk tradeoff), the self-hosted lane, the script
verify split, the own-curve kernel campaign, consensus context, and the
module split. Shared contracts in `storage/`, `mempool/`, `mining/`, and
`consensus/`.

## Apply

1. `docs/DOC_STANDARD.md`, at most 40 lines.
2. `//!` on every file under `src/`. Measured decisions stay in the module
   that owns them and name the evidence file. A module with no measured
   decision gets three lines.
3. `///` on every `pub fn` and `pub const` type in the consensus-adjacent
   modules, at most four lines, each with a fixture id, a `test "` name that
   exists in the tree, or a gate name. CLI subcommand functions get one line
   naming the gate.
4. `zig build docs` installs Zig autodoc under `zig-out/docs/`. That tree
   stays uncommitted (`zig-out/` is ignored).
5. `scripts/doc_coverage.py` emits `port.docs.coverage.v1` and is a
   `zig build test` step that reports and does not fail.

Source comments must not contain the external-path strings the extraction
guard rejects.
