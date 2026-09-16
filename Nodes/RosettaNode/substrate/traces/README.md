# Trace partition, version 1

The campaign hash-freezes the deterministic generators as well as this inventory.
Generators use integer enumeration, not ambient random seeds.

Public development: `bundles/public_check.py` and wire examples in
`contracts/WIRE_STORAGE.md`. They exercise service framing, evaluate, one durable
job, retry/conflict and shutdown. Candidates write additional tests from the full
contract. No hidden evaluator, control-host implementation, or trace is supplied.

Withheld correctness: `evaluator/corpus.py` (Bitcoin encoding family),
`tools/mutation_matrix.py`, `recovery_probe.py`, `limits_probe.py`, `edge_probe.py`,
`error_probe.py`, `after_ack_probe.py`, `priority_probe.py`, and `candidate_eval.py`.
Negative amounts remain identified as their own encoding cases. Priority traces
include an empty-side dispatch before the mixed 3:1 sequence. Saturation checks
include completed-but-uncommitted jobs. Crash boundaries are process crashes.

Withheld measurement: `tools/benchmark.py`. W1 enumerates 10,000 evaluate requests
at each batch size 1, 8 and 64. W3 enumerates client 0..7 × job 0..1249, each with
eight copies of the positive-amount transaction. W4 uses the same IDs, rotates
three encoding families (including negative amount), cancels every seventh job,
drops every eleventh admission response, and requests high priority unless job
index is divisible by four. Concurrent arrival order is intentionally not fixed;
operation intervals, durable state and priority barriers determine correctness.

Maintenance input is the retained v1 submission, its tests and concise handoff.
No lineage receives another lineage's source or results. Initial failures and
repairs remain separate. The kernel, limits, schema and v2 compatibility contract
are common; there is no language-dependent expected result.
