# Mojo Parallel Runner Research

This note records the local documentation surface behind Mojo's diagnostic
parallel script runner. The runner is under audit; comparable proof targets must
stay sequential unless a fresh artifact self-proves actual parallel batches.

## Official Docs Cached Locally

Run:

```bash
make mojo-docs-cache
make mojo-docs-status
```

The cache is generated under `.mojo-docs/` and is ignored by git. The cache now
includes these runner-relevant pages:

| Local file | Official topic |
|------------|----------------|
| `.mojo-docs/stdlib-parallelize-function.md` | `std.algorithm.backend.cpu.parallelize.parallelize` |
| `.mojo-docs/stdlib-sync-parallelize.md` | `std.algorithm.backend.cpu.parallelize.sync_parallelize` |
| `.mojo-docs/stdlib-asyncrt.md` | async runtime overview |
| `.mojo-docs/stdlib-asyncrt-task.md` | `Task` |
| `.mojo-docs/stdlib-asyncrt-raising-task.md` | `RaisingTask` |
| `.mojo-docs/stdlib-asyncrt-task-group.md` | `TaskGroup` |
| `.mojo-docs/stdlib-asyncrt-create-task.md` | `create_task` |
| `.mojo-docs/stdlib-asyncrt-parallelism-level.md` | runtime worker count |
| `.mojo-docs/stdlib-atomic.md` | atomic package overview |
| `.mojo-docs/stdlib-atomic-atomic.md` | `Atomic` |
| `.mojo-docs/stdlib-atomic-ordering.md` | memory ordering values |
| `.mojo-docs/stdlib-atomic-fence.md` | atomic fences |
| `.mojo-docs/stdlib-lock.md` | lock package overview |
| `.mojo-docs/stdlib-lock-blocking-spin-lock.md` | `BlockingSpinLock` |
| `.mojo-docs/stdlib-lock-blocking-scoped-lock.md` | `BlockingScopedLock` |
| `.mojo-docs/stdlib-sys-num-logical-cores.md` | host logical core count |

## Relevant Findings

`parallelize` is the simplest candidate for script verification jobs. The
official 1.0.0b1 docs describe an index-based API that executes
`func(0) ... func(num_work_items - 1)` as parallel subtasks, with overloads that
accept an explicit `num_workers`.

`sync_parallelize` looks tempting for a raising verifier, but the current docs
warn that exceptions raised by the callback trap instead of propagating back to
the caller. Do not use raised exceptions as the consensus failure transport for
an accepted benchmark artifact.

`TaskGroup` and `create_task` are available through the async runtime. They are
more flexible than the index-based parallelize API, but they add coroutine/task
ownership questions that are not yet proven against Mojo's current verifier
state and native shim calls.

`Atomic`, `Ordering`, fences, and `BlockingSpinLock` are available for shared
state. They are useful for a minimal first-failure index and completion counters,
but they should not become a broad mutable verifier state bag.

## Runner Shape

Build deterministic verifier work sequentially in transaction/input order. Each
job uses immutable or copy-owned data needed by the verifier: tx/input index,
spent prevout data, script/witness data, and the precomputed sighash material
for that transaction.

Execute the jobs with a non-raising callback. The callback should catch verifier
errors locally and write an owned result slot:

```text
job_index
ok
failure_stage
failure
tx_index
input_index
spent_script_pubkey
```

After all jobs complete, reduce results sequentially in job order and report the
first failing job by lowest transaction/input index. Only apply UTXO deletes and
creates after every input for the transaction passes.

Runner controls:

```text
MOJOBITNODE_PAR_SCRIPT_VERIFY=1
MOJOBITNODE_SCRIPT_THREADS=<n>
MOJOBITNODE_SCRIPT_MIN_INPUTS=<n>
```

The raw CLI and proof Make target defaults for `MOJOBITNODE_PAR_SCRIPT_VERIFY`
are `0`. Set `MOJOBITNODE_PAR_SCRIPT_VERIFY=1` only for diagnostic runner work
until the result-storage and artifact-truth audit is complete.

## Proof Requirements For Promotion

A new artifact may report `script_runner_mode="parallel"` only when all of the
following are true:

- A small Mojo toolchain smoke proves the chosen parallel API actually runs more
  than one job concurrently.
- The runner preserves deterministic first-failure reporting.
- The runner never lets callback exceptions trap the process without structured
  blocker context.
- Host and Docker corpus stay `45/45`.
- Fresh Docker 5k and 50k proofs preserve target hash and UTXO count.
- The `shakedown_50k` artifact validates under the official benchmark contract.

If any of those conditions fails, debug artifacts must report
`script_runner_mode="sequential"` and `script_runner_actual_mode="sequential"`.
