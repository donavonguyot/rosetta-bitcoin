# Follower Storage Readiness

This inventory compares follower ports against the NodeCore storage gate after
the Java native storage proof and the later C# / Cpp RocksDB cutovers.

## Recommendation

Keep C#, Cpp, Python, TypeScript, and Elixir on explicit RocksDB/native paths.
C# is the first clean follower with native storage evidence; Cpp is the systems
follower whose compliance path is explicitly RocksDB-only; Python parity is a
full break from SQLite scout state; TypeScript and Elixir now have bounded
native storage tracks that still require fresh replay before parity claims.

## Port Matrix

| Port | Current operational store | Raw block files | Storage gate status | First storage action |
|------|---------------------------|-----------------|---------------------|----------------------|
| JavaNode | Native RocksDB chainstate path proven | Yes | Passed as lead reference | Keep native storage references green |
| CSharpNode | Native RocksDB chainstate (`chainstate-rocksdb`) owns headers, UTXO, undo, tip, block index | Yes | Passed smoke/storage replay; bounded sync in progress | Keep RocksDB-only contract green and add richer status/proof exports |
| ElixirNode | RocksDB chainstate boundary/proof path; legacy SQLite path retired for Core claims | Yes | Proof partial; native secp256k1 NIF unavailable | Replace native abstraction with real RocksDB/NIF bindings and replay from empty state |
| TypeScriptNode | RocksDB `ChainstateStore` proof path; SQLite tracker remains legacy/non-Core | Yes | Proof partial after SQLite-exit storage work | Replace SQLite runtime boundary fully, keep native dependencies scoped, and replay from empty state |
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
- TypeScript has a RocksDB/native dependency path and Docker proof/supervisor
  declarations; external probe and full replay remain pending.
- Elixir has a RocksDB chainstate boundary and bounded proof; native secp256k1
  remains unavailable and live replay remains pending.
- Storage clearance does not imply consensus clearance or Docker contract
  completion; keep those gates separate in `docs/port-status.md`.

## ElixirNode Readiness

Elixir is valuable for supervision and peer lifecycle work. It now has a bounded
RocksDB chainstate proof path, but native secp256k1 and empty-datadir replay are
still required before parity claims.

## TypeScript

TypeScript has the strongest non-Java sync operations and is now allowed to enter
the native backend track. Core/native TypeScript work may add runtime npm
dependencies when they are limited to RocksDB and `libsecp256k1` infrastructure
bindings. It still must not depend on external Bitcoin libraries.
