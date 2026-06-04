# Legacy Tracker Snapshots

These JSON exports come from the historical SQLite tracker and are committed only
as checkpoint/handoff evidence. They are not native/Core chainstate proof.

Forward TypeScript native status comes from:

```bash
npm run build
npx tsbitnode-status --datadir ./data-ts
```

Legacy refresh, only when intentionally updating old tracker evidence:

```bash
npm run build && npm run export:snapshots -- --db ./data-ts/tsbitnode.db
```

| File | Contents |
|------|----------|
| `manifest.json` | Export metadata and file list |
| `status.json` | Legacy tracker summary |
| `phases.json` | Roadmap phase status and notes |
| `wire.json` | Wire capability progress and checkpoints |
| `capabilities.json` | Per-capability implementation/verification state |

Use native proof JSON under `Nodes/Shared/conformance/results/` for Core storage
evidence.
