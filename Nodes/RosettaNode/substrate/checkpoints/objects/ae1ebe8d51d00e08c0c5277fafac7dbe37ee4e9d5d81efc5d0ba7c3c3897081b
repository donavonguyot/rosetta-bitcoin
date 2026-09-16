# Substrate trial preregistration

Status: preparation; neither gate is frozen and no candidate may start.
Two independent lineages per language: Go, Rust, Zig. This is an operational
host trial using a common encoding kernel, not a node or consensus experiment.
The completed parent transfer experiment is immutable.

Predictions, recorded before candidate construction:

- Rust and Zig may have similar ABI/service overhead. Go may pay additional
  crossing/copy cost; batching may recover some of it.
- Fixed synchronous-write performance may be storage dominated and weak evidence
  for language selection.
- Model familiarity may favor Go/Rust maintenance over Zig 0.16. Attribute API
  fluency, toolchain, evaluator and design failures separately, with evidence.
- Rust may remain non-dominated. This prediction establishes no preferred winner.
- Zig maintenance evidence remains useful independently of substrate selection.

Same model/configuration for all candidates. No node trees, Bitcoin libraries,
other candidates or evaluator dependencies. Equal infrastructure capabilities and
pinned offline language/stdlib documentation. No prescribed host architecture.

Initial: 90 min; maintenance: 60 min; optimization: 60 min; reading: 10 min per
round. Initial and maintenance each allow one 15 min repair. These are ceilings;
record actual elapsed effort, usage and unknown cost. Fresh sessions per round,
with source/tests and predecessor handoff only. Retain every attempt; unresolved
hard failures stop dependent rounds. At most three optimization hypotheses,
including group commit. No rewrite or kernel/durability substitution.

Performance: workload 1 overhead first; workload 3 baseline versus optimization;
workload 4 tails/fairness. Workload 2 is correctness only. One warm-up on its own
volume, seven measured fresh volumes, prepared outside timing, rotated order,
serial measurement, no overlapping node benchmarks. Failed/time-out repetitions
are retained, not replaced. Fifteen minute timeout; deliberate barrier holds
excluded from liveness deadlines. Observe compaction/flush/write/stall activity.

Maintenance tuple: completion before repair; failed semantic families; repair
and implementation time/usage; diff footprint split production/test/generated.
Diff measures invasiveness, not quality. Runtime differences within 10% are an
operational tie, never a correctness allowance or statistical significance.

Sole substrate requires both lineages qualified and no material opposing
advantage. A finalist may have one qualifying lineage if the other has a scoped,
documented toolchain/evaluator failure rather than a design failure. Systemic
evaluator defects invalidate comparisons. No sole recommendation is permitted.
Report individual lineages, medians/ranges and missing evidence, including the
Zig maintenance result versus the prior.

A Zig failure is not evidence that Zig is a bad language.

Both Gate A and Gate B must be executed and hash-frozen before lineage 1. Later
instrument fixes require a new version and explicit invalidation; do not pool.
