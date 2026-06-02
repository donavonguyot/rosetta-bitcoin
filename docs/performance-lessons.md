# Performance Lessons

Performance claims must cite the measured surface: host vs Docker, fresh proof
vs persistent supervisor, chunk size, report cadence, and whether script
verification was active.

## Known Lessons

- Large blocks and tapscript mega-witnesses dominate some ranges; do not project
  tip sync from easy early blocks alone.
- Docker proofs need in-container progress reporting. Host-side I/O or wall-clock
  waits can mislead when the node process is blocked.
- Restart overhead between chunks is part of supervisor throughput. Measure both
  per-chunk validation time and inter-chunk delay.
- `POLL_SEC` must not throttle chunk turnover; use a separate `CHECK_SEC`.
- Native crypto and RocksDB reduced bounded Java/C# proof time materially, but
  binary gate confidence still depends on reaching and maintaining current tip.

## Report Template

```text
implementation:
runtime_surface:
datadir_or_volume:
chunk_size:
report_interval_sec:
check_interval_sec:
start_height:
end_height:
elapsed_sec:
blocks_per_min:
current_blocker:
notes:
```
