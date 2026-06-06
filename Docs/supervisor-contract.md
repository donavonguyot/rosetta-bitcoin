# Supervisor Contract

Persistent sync supervisors exist to find the next honest blocker without
discarding validated state between code fixes.

## Required Behavior

- Reuse the same datadir or Docker volume unless a proof explicitly requires a
  fresh state.
- Hold or respect the port's single-writer lock for each sync chunk.
- Pause on blocker or runtime error without deleting state.
- Resume after a code change or explicit resume marker.
- Support an explicit stop marker.
- Report live status from inside the runtime surface, especially for Docker.
- For Docker supervisors, follow
  [`../Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md`](../Nodes/Shared/docker/DOCKER_RUNTIME_CONTRACT.md),
  update the port manifest in `Nodes/Shared/docker/ports/`, and query Project
  Docker coverage instead of hand-maintaining Markdown rows.
- Docker supervisors that run inside the official local Reference topology must
  use `Nodes/Shared/docker/reference_topology.env` through
  `REFERENCE_TOPOLOGY_ENV`, including direct script execution. Do not hardcode a
  separate `docker compose -f ...` path or a different default peer.
- If a Docker supervisor performs local Reference P2P work, default its peer to
  `REFERENCE_P2P_PEER` on `REFERENCE_DOCKER_NETWORK`. Host-loopback peers such
  as `127.0.0.1:48333` are host/manual diagnostics, not Docker supervisor
  defaults.

## Cadence Rule

Separate reporting cadence from chunk-completion checks:

```text
POLL_SEC  = chat/operator status cadence
CHECK_SEC = fast container/process completion check cadence
```

CSharpNode proved this matters: using a 120-second report interval as the chunk
completion check throttled 500-block chunks by minutes. Splitting `CHECK_SEC`
from `POLL_SEC` restored expected throughput.

## Truthfulness Rule

Status ticks must report active backend height and current blocker. A supervisor
must not convert "process still running" into proof of progress; it must emit
heights, status, and blocker fields from the runtime.

## Smoke Versus Network Proof

A one-shot supervisor smoke proves loop mechanics: image builds, container
starts, status is read from inside the runtime surface, and
`AGENT_LOOP_TICK_chatreport` is emitted. Long-run ports may also emit
`benchmark.telemetry_tick` JSONL for `Project/scripts/monitor_benchmark_telemetry.py`.
It must not require peer reachability.

Network proof is separate. Official local Reference P2P work uses the shared
Reference Docker topology: `REFERENCE_TOPOLOGY_ENV`,
`REFERENCE_DOCKER_NETWORK`, and `REFERENCE_P2P_PEER`. External network probes
must require an explicit peer override. Host-loopback or host-forwarded peers
are diagnostic/manual routes and must not become the Docker supervisor default.
