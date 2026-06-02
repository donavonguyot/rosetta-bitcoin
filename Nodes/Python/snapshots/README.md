# Tracker snapshots

JSON exports of the live SQLite tracker (`data/pybitnode.db`). The database itself is gitignored; these files capture project progress for version control.

| File | Contents |
|------|----------|
| `manifest.json` | Export metadata and file list |
| `status.json` | Full summary (`pybitnode-db` default output) |
| `phases.json` | Roadmap phase status and notes |
| `wire.json` | Wire capability progress and checkpoints |
| `capabilities.json` | Per-capability implementation/verification state |

## Refresh

```bash
.venv/bin/python scripts/export_snapshots.py --db ./data/pybitnode.db
```

Or after syncing:

```bash
.venv/bin/pybitnode-sync --datadir ./data --blocks-max 200
.venv/bin/python scripts/export_snapshots.py --db ./data/pybitnode.db
git add snapshots/ && git commit -m "Update tracker snapshots"
```
