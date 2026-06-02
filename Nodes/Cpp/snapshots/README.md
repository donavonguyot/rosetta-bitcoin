# Tracker snapshots

JSON exports of the live SQLite tracker (`data-cpp/cpbitnode.db`). The database itself is gitignored; these files capture project progress for version control.

| File | Contents |
|------|----------|
| `manifest.json` | Export metadata and file list |
| `status.json` | Full summary (`cpbitnode-db` default output) |
| `phases.json` | Roadmap phase status and notes |
| `wire.json` | Wire capability progress and checkpoints |
| `capabilities.json` | Per-capability implementation/verification state |

## Refresh

After updating the local tracker database:

```bash
cmake --build build --target cpbitnode-export-snapshots
./scripts/export_snapshots.sh --datadir ./data-cpp --out snapshots
# or directly:
./build/cpbitnode-export-snapshots --db ./data-cpp/cpbitnode.db --out snapshots --chain testnet4
```

Writes `status.json` (with `exported_at`), `phases.json`, `wire.json`, `capabilities.json`, and `manifest.json` matching PythonNode / TypeScriptNode layout.
