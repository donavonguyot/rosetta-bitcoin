# SwiftNode

SwiftNode is a Swift baseline port shaped around the repository's strict 5k
Project interface. The first command surface is intentionally narrow:

For code structure and design rationale, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
For imported Swift posture, use Project reports from the repository root:

```bash
python3 Project/scripts/report.py --db Project/project.db --section port-status
python3 Project/scripts/report.py --db Project/project.db --section consensus-runway
python3 Project/scripts/report.py --db Project/project.db --section baseline-5k
```

Query Project for current imported runway posture instead of treating README
proof notes as live status.

- `swiftbitnode status`
- `swiftbitnode script-corpus`
- `swiftbitnode proof-local`

The Docker targets mirror `Nodes/Shared/templates/port-baseline-5k/` and emit
Project-importable artifacts under `Nodes/Shared/conformance/results/`.

```bash
make test
make docker-config
make docker-warm
make docker-script-corpus
make docker-proof-local
```

Binary testnet4 tip maintenance remains outside this initial 5k baseline.
