# Port Docker Inventory Projection

Current per-port Docker facts are not maintained in this Markdown file. Docker
truth is declared in the JSON manifests under `Nodes/Shared/docker/ports/` and
projected through `Project/project.db`.

Use the manifest validator after Docker-surface changes:

```bash
python3 Nodes/Shared/docker/validate_docker_contract.py
python3 Nodes/Shared/docker/validate_docker_contract.py --strict
```

Use Project for current Docker coverage and runnable command surfaces:

```bash
python3 Project/scripts/import_all.py --db Project/project.db --rebuild
python3 Project/scripts/report.py --db Project/project.db --section docker-coverage
python3 Project/scripts/report.py --db Project/project.db --section command-surface

sqlite-utils query Project/project.db \
  "select * from docker_coverage order by port"

sqlite-utils query Project/project.db \
  "select port, command_key, supported, command from port_command_surface order by port, command_key"
```

## Durable Rules

- Every port must have a manifest at
  `Nodes/Shared/docker/ports/<port>.docker.json`.
- Manifest `commands` entries map the standard Docker contract surface to the
  port's current idiomatic commands.
- Proof result JSON belongs in `Nodes/Shared/conformance/results/`; do not keep
  Docker volumes, full logs, or port-local proof datadirs as project evidence.
- Reference is a peer service recipe, not a follower implementation proof.
- A clean validator report proves the manifest is complete enough to reason
  about; it does not prove the Docker command passed.

See `DOCKER_RUNTIME_CONTRACT.md` for required fields, standard command names,
volume rules, peer modes, and ratchet order.
