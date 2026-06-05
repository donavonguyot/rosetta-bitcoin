# Java RocksDB Runtime

JavaNode keeps raw block bytes in flat files, and all node-local KV state lives
in RocksDB:

```text
operational-rocksdb/   metadata, headers, block index, sync state, events
utxo-rocksdb/          active UTXO set, undo, validated tip, backend metadata
blocks/                raw block files
.jbitnode_native_storage
```

`Project/project.db` remains top-level mission-control state. Java status export
may be imported there by Project scripts, but Java sync/status/live/rebuild use
RocksDB for runtime truth.

## Operational RocksDB Keyspace

Operational keys cover runtime metadata:

```text
m/<key>                         meta
h/<chain>/<height>              headers
b/<chain>/<height>              block index
s/<chain>                       sync state
t/<chain>                       validated tip mirror for operational callers
e/<monotonic-event-id>          events
c/<name>                        counters
```

## Acceptance Target

```text
- Java sync/status/live/rebuild start from RocksDB.
- Fresh datadir writes headers, blocks, sync state, events, and validated tip to
  RocksDB stores.
- Status reports RocksDB backend paths, validated height/hash, and block index
  heights from RocksDB.
```
