# Follower Port Gate

Follower-port storage work should wait until Java has both references:

```text
Java stable reference:
  sync-capable
  green tests
  usable for live blocker discovery

Java native storage reference:
  fresh datadir starts in the intended native backend
  headers and block index persist in native chainstate
  blocks connect and restart from native chainstate
  status reads active stores
  Project/project.db export is observational only
```

## Gate For Starting Storage Ports

A follower port can begin broad storage work when Java's native storage reference
passes the canonical storage gate in [`storage/STORAGE_GATE.md`](storage/STORAGE_GATE.md):

```text
mvn verify
native fresh-start test
native restart test
local SQLite artifact absence test
project export test
offline replay benchmark
```

## Current Java Evidence

Java's native storage gate has concrete proof artifacts:

```text
status snapshot: Project/project.db node_id=javanode-native-storage
conformance results:
  NodeCore/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json
  NodeCore/conformance/results/java_rocksdb_codec_v2_storage_shared_2026-06-01.json
fresh sync: passed, validated_height=1
restart sync: passed, validated_height=2
local SQLite artifact absence: passed
project export: passed
forbidden local SQLite artifact in native datadir: absent
```

This evidence proved the Java storage shape was ready for follower-port
planning. The current strategic target for serious ports is now RocksDB plus
NodeCore Chainstate Codec v2.
Followers still need their own local implementation and result records before
claiming the same gate.

The follower readiness inventory is tracked in
[`FOLLOWER_STORAGE_READINESS.md`](FOLLOWER_STORAGE_READINESS.md). It selects
`CSharpNode` as the first storage-gate follower and `TypeScriptNode` as the
fallback if C# is deferred.

## Independence Rule

Follower ports may copy fixture facts and expected outcomes from NodeCore, but
they must not treat Java output as a validity oracle. Clearance requires local
code, local tests, and a status or conformance result for that port.
