# Tracker snapshots

Historical JSON exports; forward exports come from the live RocksDB native tracker (`data/chainstate-rocksdb`). The native state itself is gitignored; these files capture project progress for version control.

| File | Contents |
|------|----------|
| `manifest.json` | Export metadata and file list |
| `status.json` | Full summary (`pybitnode-status` default output) |
| `phases.json` | Roadmap phase status and notes |
| `wire.json` | Wire capability progress and checkpoints |
| `capabilities.json` | Per-capability implementation/verification state |

## Refresh

```bash
.venv/bin/python scripts/export_snapshots.py --state-path ./data/chainstate-rocksdb
```

Or after syncing:

```bash
.venv/bin/pybitnode-sync --datadir ./data --blocks-max 200
.venv/bin/python scripts/export_snapshots.py --state-path ./data/chainstate-rocksdb
git add snapshots/ && git commit -m "Update chainstate snapshots"
```
