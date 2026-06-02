# Follower Storage Readiness

This inventory compares follower ports against the NodeCore storage gate after
the Java native storage proof and the later C# / Cpp RocksDB cutovers.

## Recommendation

Keep C#, Cpp, and Python on explicit RocksDB/native paths. C# is the first clean
follower with native storage evidence; Cpp is the systems follower whose
compliance path is explicitly RocksDB-only; Python parity is a full break from
SQLite scout state and must replay blockers from empty native state.

`TypeScriptNode` remains a native-backend candidate only if its no-runtime-npm
dependency rule is revisited.

## Port Matrix

| Port | Current operational store | Raw block files | Storage gate status | First storage action |
|------|---------------------------|-----------------|---------------------|----------------------|
| JavaNode | Native RocksDB chainstate path proven | Yes | Passed as lead reference | Keep native storage references green |
| CSharpNode | Native RocksDB chainstate (`chainstate-rocksdb`) owns headers, UTXO, undo, tip, block index | Yes | Passed smoke/storage replay; bounded sync in progress | Keep RocksDB-only contract green and add richer status/proof exports |
| ElixirNode | `exbitnode.db` SQLite owns headers, UTXO, undo, tip, block index | Yes | Not attempted | Keep consensus progress on exqlite while planning native chainstate |
| TypeScriptNode | Node SQLite tracker owns operational truth | Yes | Not attempted | Defer native backend until runtime-deps rule is revisited |
| CppNode | RocksDB `NodeStateStore` owns operational state in native mode | Yes | Proof partial after RocksDB-only cutover | Rerun live staged sync and keep native builds SQLite-free |
| PythonNode | RocksDB native tracker path replaces legacy SQLite scout state for forward work | Yes | Bounded proof path in progress; full replay pending | Validate native proof/supervisor, then run blocker discovery in a separate empty-datadir replay plan |

## Current Follower Notes

- C# has RocksDB/native evidence and persistent Docker supervisor status, but
  P2TR script-path at height 22830 remains a consensus blocker.
- Cpp has a RocksDB-only operational store and native proof infrastructure, but
  staged live sync still needs to be rerun before promotion.
- Python's old SQLite blocker trail is historical handoff evidence only. The
  native-break work creates the RocksDB/native-crypto/Docker surface, but parity
  still waits for a separate empty-datadir replay plan to rediscover blockers.
- Storage clearance does not imply consensus clearance or Docker contract
  completion; keep those gates separate in `docs/port-status.md`.

## ElixirNode Readiness

Elixir is valuable for supervision and peer lifecycle work, but it is not the
best first storage-gate follower. It has a working `exqlite` baseline and flat
block files, but the NIF/native backend decision should wait until the storage
contract and C# follower shape are clearer.

## TypeScript

TypeScript has the strongest non-Java sync operations, but native backend work
would conflict with its current zero runtime npm dependency rule.
