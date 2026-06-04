# NodeCore Replay Telemetry v1

Replay telemetry v1 is the shared evidence format for offline and Docker replay
proofs across ports. It standardizes how we measure replay behavior without
standardizing how long any port is allowed to run.

## Goals

- Compare replay proofs by validated height, result, runtime surface, and
  normalized stage timings.
- Preserve per-port proof detail while exposing common fields for dashboards and
  quick reviews.
- Make Docker proof introspection consistent enough to answer:
  "what ran, how far did it validate, what was slow, and did it block?"
- Keep the binary node gate separate from replay proof. A local-reference replay
  can be excellent evidence and still not be live P2P tip maintenance.

## Canonical Artifact

Canonical replay artifacts use:

```json
{
  "schema_version": 1,
  "artifact_kind": "nodecore.replay_telemetry",
  "run_id": "go-docker-pipeline-137742-20260603T120000Z",
  "implementation": "GoNode",
  "port": "go",
  "runtime_surface": "docker",
  "replay_mode": "pipeline",
  "chain": "testnet4",
  "target_height": 137742,
  "validated_height": 137742,
  "validated_hash": "...",
  "result": "passed",
  "stage_totals_ms": {
    "prevout_batch_load": 523072,
    "script_verify": 1367368,
    "commit": 88668,
    "block_connect_store_commit": 2534953
  }
}
```

The schema is intentionally additive. Ports may include extra fields, but the
required fields must remain stable.

## Stage Names

Ports should map their local timers to these stage names when possible:

| Stage | Meaning |
|-------|---------|
| `block_read` | Read or receive raw block bytes |
| `block_parse` | Decode block and transaction structures |
| `prevout_batch_load` | Load external prevouts for a block |
| `script_verify` | Consensus script verification |
| `utxo_apply` | Build spend/create mutations in memory |
| `commit` | Durable chainstate write |
| `block_connect_store_commit` | End-to-end ordered block connect and store path |

Unknown or port-specific stages may remain in `stage_totals_ms`. Comparators
must not fail just because a port records more stages.

## Tooling

Validate a canonical artifact:

```bash
python3 NodeCore/replay/tools/validate_replay_telemetry.py \
  NodeCore/conformance/results/go_replay_telemetry_docker_tip_137742_2026-06-03.json
```

Normalize an existing raw proof artifact:

```bash
python3 NodeCore/replay/tools/capture_docker_replay.py \
  --from-result NodeCore/conformance/results/go_local_reference_docker_sync_tip_137742_2026-06-03.json \
  --output NodeCore/conformance/results/go_replay_telemetry_docker_tip_137742_2026-06-03.json
```

Compare multiple raw or canonical artifacts:

```bash
python3 NodeCore/replay/tools/compare_replay_telemetry.py \
  NodeCore/conformance/results/*local_reference*dock*sync*.json
```

## Runtime Boundaries

Replay telemetry v1 measures proof runs. It does not change consensus rules,
does not permit trusted imports, and does not upgrade a port's live-sync status.
Use `docs/port-status.md` and the Docker inventory for port status, and use this
artifact only as standardized replay evidence.
