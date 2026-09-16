# RosettaNode substrate trial — running report

**The experiment is in progress. There is no substrate recommendation yet.**
No node, consensus, readiness or Project claim follows from this trial.

## What the instrument established

The C control passed the independently inspected service-state checks, C API/WAL
interposition, process-crash boundaries, capacity accounting, cancellation,
v1-to-v2 recovery and priority scheduling. The seeded early-ack, torn-state,
conflict, late-cancellation, arena-lifetime and starvation defects failed their
intended checks with unaffected controls retained. Fresh-container semantic
manifests agreed. Workload controls passed, including 10,000 durable jobs and
mixed-service response loss. The exact loaded RocksDB library is Debian 7.8.3-2;
all candidates use its C API and the same LLVM encoding adapter.

The preparation checkpoint and artifacts distinguish elapsed wall time from
unknown model-active time. They do not assign invented prices to model usage.

## An evaluator error, not two language errors

Evaluator v1 incorrectly demanded a JSON `execution_failure` response after an
injected admission-write failure. The contract allowed diagnostic shutdown
without accepting the job. Go-1 and Zig-1 both implemented that legal EOF path;
the evaluator rejected them. The Go repair agent independently built a native
fault injector and reproduced the empty response. Reviewing that evidence exposed
the test's unstated requirement.

Further launches were paused. V1 source, freeze, submissions, repairs and results
remain retained. V2 accepts EOF or an explicit error response while still
requiring nonzero termination, no false acceptance and independently valid
persistent state. A new EOF control passes; the early-ack mutant still fails.
The candidate contract did not change. Both untouched initial submissions pass
v2, and their binaries reproduce byte-for-byte in fresh pinned builds.

All semantic comparisons will use v2 outcomes. Evaluator-induced repair time is
reported separately and excluded from language maintenance cost. Maintenance
starts from the untouched passing submissions, not those unnecessary repairs.
This is a concrete limit of qualifying an evaluator against one correct dummy:
the dummy can share an unjustified assumption with the test. Independent hosts
exposed a permitted behavior the control had not exercised.

## Diagnostic asymmetry

Go-1 passes the native adapter ASan lane and the v2 evaluator using a Go
race-instrumented executable. This covers exercised Go races and instrumented
native adapter accesses; it proves neither native-library race freedom nor
absence of untested defects.

Zig-1's preloaded ASan runtime fails during thread teardown in
`UnsetAlternateSignalStack`/`UnmapOrDie`. A minimal four-thread Zig program, with
no candidate code, adapter or RocksDB, reproduces the same failure and runs
successfully without ASan. This lane is unsupported on the pinned combination;
it is not a demonstrated service memory fault, and it is not a clean sanitizer
result. The raw diagnostic and attribution are separate retained artifacts.

A Zig failure is not evidence that Zig is a bad language.

## Interim candidate results

All six original initial submissions pass semantic evaluator v2. None required
repair for an established service-contract defect. This is evidence that the
bounded host contract and equal-capability bundles are implementable in all
three languages with this model; it is not yet evidence of equal maintenance
cost or runtime performance.

The first Zig and Go fresh-agent maintenance submissions pass all 28 families
without repair, including ABI v2, pending-v1 recovery and priority scheduling.
Their implementation phase wall times were approximately 10.3 and 9.7 minutes.
The second lineages and runtime results are still pending. These observations
challenge the preregistered concern about Zig maintenance familiarity without
establishing a language ranking.

## Controller and storage limitations

The initial broker could replay already completed build requests on a later
phase. Controller v3 skips completed requests and archives each phase queue;
a regression exercises both skipped and new work. Initial construction times
are descriptive only and cannot support a speed ranking. Maintenance and
optimization use the corrected controller. All superseded records remain.

Docker storage exhaustion interrupted Zig-2 evaluation before a semantic result.
Its unchanged original source passed after trial-owned stopped container state
was archived and verified. The short, unnecessary repair made no production or
binary change and is excluded from language cost. Unrelated Docker state was
not pruned; failed trial volumes remain retained.

A controller process-matching error briefly allowed four development sessions
instead of two. It was corrected before performance measurement. Per-runtime
limits were unchanged, but phase wall times include this recorded background
load and should not be interpreted as isolated language costs.

## Interpretation still pending

Initial construction, fresh-agent maintenance and optimization remain separate
questions. One successful lineage cannot establish language superiority. Final
reporting will show both lineages, gates before repair, semantic failures,
implementation and repair effort, usage, diff footprint, diagnostic coverage,
workload-specific performance and the preregistered prior. A runtime difference
within 10% is an operational tie, not a statistical result.

Runtime state and full transcripts are local and ignored. Compact evidence stays
under this package and outside Project. The parent transfer experiment remains
unchanged. See `evidence/analysis-v2.json` for current structured accounting and
`evidence/instrument-correction-v2.json` for the versioned evaluator correction.
