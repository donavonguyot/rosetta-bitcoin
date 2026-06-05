# Cpp Project Status Guide

This file is a pointer, not a hand-maintained status dashboard. Current imported
Cpp status, Docker coverage, conformance, blocker, and benchmark summaries live
in `Project/project.db`.

Use the Project projections:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage
python3 Project/scripts/report.py --db Project/project.db --section benchmark-summary
sqlite-utils query Project/project.db \
  "select * from latest_port_status where port = 'cpp'"
```

Durable Cpp evidence remains in:

- `Nodes/Cpp/docs/BLOCKER_LEDGER.md` for blocker handoff facts.
- `Nodes/Cpp/README.md` for local build, proof, and run commands.
- `Nodes/Shared/conformance/results/` for compact proof JSON.

Cpp native/Core compliance remains RocksDB-only: headers, block index, sync
state, blocker state, status truth, UTXO, undo, metadata, and validated tip are
RocksDB runtime truth.
