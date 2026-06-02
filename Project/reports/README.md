# Project Reports

Reports compare ports from exported observations in `Project/project.db`.

Initial report families:

```text
height-status.md
blockers.md
conformance.md
backends.md
performance.md
binary-gate.md
```

## Report Rules

- Reports are generated from `Project/project.db`, not from live node datadirs.
- Reports must identify the captured timestamp and source run.
- Reports must distinguish active backend state from project observations.
- A port is not marked as passing the binary gate unless its exported status says
  the active chainstate validated to tip independently.

## Suggested Matrices

- per-port `validated_height`, `header_height`, `sync_status`
- blocker clearance by height and script rule
- conformance fixture pass/fail by implementation
- active backend inventory and generation status
- timing comparison by block, range, stage, and backend
