# Java Runtime Storage Boundary

JavaNode has completed the clean runtime cutover: normal sync, live, rebuild, and status commands use native operational state only. A port-local operational DB outside the approved native backend is no longer a supported Java runtime path.

## Runtime State

Java runtime state lives under the datadir as:

```text
operational-rocksdb/
utxo-rocksdb/
blocks/
.jbitnode_native_storage
```

`ChainstateSession` always opens the native `OperationalStore` and native chainstate backend. Compatibility-store promotion and mirror UTXO stores are intentionally unsupported for this cutover.

## Commands

The normal commands are now native by default:

```bash
make java-node-sync-chunk
make java-node-live
make java-node-status
```

The normal Make targets set `UTXO_BACKEND=rocksdb` and `ROCKSDB_DIR` explicitly.

## Project Mission-Control DB

`Project/project.db` remains top-level observational state. Java emits status JSON; Project scripts import that JSON when mission-control rows are needed.

```bash
make java-node-status DATA_DIR=./data-java > /tmp/javanode-status.json
python3 Project/scripts/import_status_snapshot.py \
  --db Project/project.db \
  --node-id javanode \
  /tmp/javanode-status.json
```

Java runtime code must not write `Project/project.db` directly.

## Cutover Proof

As of 2026-06-01, a fresh isolated datadir `data-java-clean-cutover-smoke` passed the clean runtime smoke against testnet4 peer `89.167.10.150:48333`:

```text
fresh sync validated_height=1
restart sync validated_height=2
chainstate_backend=rocksdb
chainstate_status=usable
jbitnode.db absent
Project status import performed by Project/scripts/import_status_snapshot.py
```
