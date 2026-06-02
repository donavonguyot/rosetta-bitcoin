# Follower Storage Readiness

This inventory compares follower ports against the NodeCore storage gate after
the Java native storage proof.

## Recommendation

Use `CSharpNode` as the first storage-gate follower. It is the intended clean
follower in `SPEC.md` and `CSharpNode_FOLLOWER.md`, and its current shape is
small enough to refactor before more live-chain state accumulates.

`TypeScriptNode` is the best fallback if C# is deferred, but its no-runtime-npm
dependency rule makes native KV adoption a separate product decision.

## Port Matrix

| Port | Current operational store | Raw block files | Storage gate status | First storage action |
|------|---------------------------|-----------------|---------------------|----------------------|
| JavaNode | Native RocksDB chainstate path proven | Yes | Passed as lead reference | Keep native storage references green |
| CSharpNode | Native RocksDB chainstate (`chainstate-rocksdb`) owns headers, UTXO, undo, tip, block index | Yes | Passed smoke/storage replay; bounded sync in progress | Keep RocksDB-only contract green and add richer status/proof exports |
| ElixirNode | `exbitnode.db` SQLite owns headers, UTXO, undo, tip, block index | Yes | Not attempted | Keep consensus progress on exqlite while planning native chainstate |
| TypeScriptNode | Node SQLite tracker owns operational truth | Yes | Not attempted | Defer native backend until runtime-deps rule is revisited |
| CppNode | SQLite tracker owns operational truth | Yes | Not attempted | Clear consensus blocker path before storage gate |
| PythonNode | SQLite scout store | Yes | Not attempted | Keep as scout and fixture generator |

## CSharpNode Readiness

Strengths:

- Existing flat block store already matches the raw byte storage direction.
- Existing datadir lock gives a starting point for single-writer enforcement.
- `BlockConnector` already has block-local UTXO logic that can move behind an
  active chainstate store.
- The port is early enough that replacing SQLite truth is still cheaper than
  preserving long-term compatibility.

Risks:

- Long-lived consensus status is ahead of port-local docs; the C# ledger and
  shared matrix need to be updated from current durable evidence.
- `export-snapshots` is still a stub, so C# has status JSON but not the full
  Python/TypeScript snapshot package.
- P2TR script-path at height 22830 is the next consensus blocker; storage gate
  clearance does not imply tapscript clearance.

## ElixirNode Readiness

Elixir is valuable for supervision and peer lifecycle work, but it is not the
best first storage-gate follower. It has a working `exqlite` baseline and flat
block files, but the NIF/native backend decision should wait until the storage
contract and C# follower shape are clearer.

## TypeScript, C++, Python

TypeScript has the strongest non-Java sync operations, but native backend work
would conflict with its current zero runtime npm dependency rule. C++ is a good
future native-KV candidate after consensus progress improves. Python should
remain the scout and fixture generator rather than lead a storage migration.
