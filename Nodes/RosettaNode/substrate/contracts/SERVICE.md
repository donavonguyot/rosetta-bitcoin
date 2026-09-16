# Shared service contract v1/v2

Effective only with a matching campaign-freeze.json; Gate A and Gate B must pass before launch.

Linux AArch64, LLVM 18.1.3, Zig 0.16.0, Go 1.27.1, Rust 1.98.1. Four CPUs,
four GiB. Debian librocksdb7.8 and librocksdb-dev exactly 7.8.3-2. All writes
through the dynamic C API, same designated shared-object digest/build-id.
Compression off; 128 MiB block cache; 64 MiB write buffer; two buffers and two
background jobs. Multi-key transitions use WriteBatch, WAL enabled, sync=true.

| Limit | Value |
|---|---|
| Adapter batch | 64 transactions, 16 MiB aggregate bytes |
| Per transaction | 4 MiB, 4,096 combined items |
| JSON request text | 40 MiB |
| Concurrent clients | 8 |
| Admitted nonterminal work | 1,024 jobs AND 64 MiB payload |
| Optimization group commit | 32 jobs, at most 2 ms intentional wait |

Queued, running and completed-but-uncommitted jobs count until durable terminal
receipt. Head-of-line backpressure is legitimate. Immutable arena input remains
owned until every worker returns; cancellation cannot free it early.

Transport is Unix stream sockets, UTF-8 JSON lines, request correlation `request`
and stable `id`. Operations: submit, cancel, status, shutdown; acknowledgements
and terminal notifications. Unknown status/cancel returns not_found without
rows. Identical retry returns existing state; a different digest returns
conflict. Disconnect never cancels. Terminal receipts remain queryable after
notification loss. Admission acknowledgment promises durable complete payload.

Admission atomically writes pending payload, digest, sequence, metadata and
outstanding accounting. Terminal commits follow admission order and atomically
write receipt, remove pending/cancel state, release accounting and advance the
contiguous checkpoint. Accepted cancellation durably writes its intent before
acknowledgment and is idempotent. Disk schema is explicitly versioned and must
include all recovery information. The independent inspector opens the database
only after its writer stops. Candidate status is not the oracle.

Terminal commitment begins at entry into the interposed C WriteBatch containing
the terminal transition (every included sequence for a group). Completed
cancellation before that boundary must be honored. After it, cancellation returns
too_late or an already-terminal disposition. Overlap must permit a legal ordering
based on operation intervals; socket arrival order is insufficient. Release
barriers before judging liveness and exclude hold time. Crashes may retain the
complete old or new transition, never torn state. One writer; draining shutdown.

ABI v2 changes per-item pointers to arena offsets and adds success bitmap with
per-item statuses. Kernel unchanged. V2 recovers pending v1 at normal priority,
preserves cancellations/receipts, never rebuilds and rejects incompatible schema.
When both priority queues are nonempty, dispatch three high then one normal;
when only one is nonempty, dispatch it without advancing the cycle. FIFO within
queues; terminal commitment remains admission ordered.

Baseline uses one job per admission and terminal WriteBatch. Group commit is an
optimization-only lane with identical durability, bounded waits, batch histogram
and separate write/sync counts. Cancellation intent also requires sync/WAL.

Wire field encodings are defined in WIRE_STORAGE.md. Trace partition and exact
generators are frozen in the campaign manifest. This prose alone is not gate evidence.

Interposer event interpretation: `call_entry` timestamps entry into the C write
wrapper. `write_member` records every pending/receipt/cancellation key associated
with that call ID, including group commits. `write_enter` is the barrier just
before invoking the real C function, after observing batch membership. Terminal
commitment begins at call_entry for every terminal member of the batch. WAL
syncs and native success share the call ID; initialization has no job member.
