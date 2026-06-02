# Tracker snapshots

JSON exports of the live SQLite tracker (`data-ts/tsbitnode.db` by default). The database itself is gitignored; these files capture project progress for version control.

| File | Contents |
|------|----------|
| `manifest.json` | Export metadata and file list |
| `status.json` | Full summary (`tsbitnode-db` default output) |
| `phases.json` | Roadmap phase status and notes |
| `wire.json` | Wire capability progress and checkpoints |
| `capabilities.json` | Per-capability implementation/verification state |

## Refresh

```bash
npm run build && npm run export:snapshots -- --db ./data-ts/tsbitnode.db
```

**When to commit:** export and commit `snapshots/` after meaningful milestones — e.g. a checkpoint passes (`full_node_wire_ready` flips, a phase completes, or a batch sync target is reached). Always export when the DB is **quiescent** (between batches, not mid-write).

Or after a batch sync completes (DB quiescent — not mid-write):

```bash
./scripts/sync_batch_loop.sh --datadir ./data-ts --target 10000 --blocks-max 200
npm run export:snapshots -- --db ./data-ts/tsbitnode.db
git add snapshots/ && git commit -m "Update tracker snapshots"
```

Check progress without opening the DB for writes:

```bash
npm run sync:progress -- --db ./data-ts/tsbitnode.db --target 10000
npm run sync:progress -- --db ./data-ts/tsbitnode.db --target 10000 --json
```

See [README Operations](../README.md#operations) for batch sync, connect-only, and parallel PythonNode workflows.
