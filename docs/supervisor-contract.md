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
