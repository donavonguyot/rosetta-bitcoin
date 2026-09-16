# Wire and storage contract, version 1

Effective only under the hash-recorded campaign freeze.

Every request is one UTF-8 JSON object and newline. `request` is an opaque
correlation string. Job IDs match `[A-Za-z0-9_-]{1,64}`. Integers below are decimal
strings; hex is lowercase, even length. Unknown fields are reserved. Reject
invalid requests without state changes. Per-client request/response order is
preserved; terminal event lines may arrive between responses.

```
{"request":"a","op":"submit","id":"job","items":[{"hex":"01000000000000000000","mode":"witness","operation":"exact"}]}
{"request":"a","status":"accepted","sequence":"1"}
{"request":"b","op":"status","id":"job"}
{"request":"c","op":"cancel","id":"job"}
{"request":"d","op":"shutdown"}
{"request":"e","op":"evaluate","items":[...]}
```

`evaluate` is the nonpersistent workload-1/2 path. Items have `mode` legacy or
witness, and `operation` prefix or exact. The batch is nonempty. Input bytes are
passed to the supplied kernel through the C adapter; do not implement Bitcoin
logic in the host. Evaluation returns status `ok` with `results`. Each result has
decimal-string `status`, `consumed`, `full_size`, `stripped_size`, and 32-byte hex
`txid_digest_order`, `wtxid_digest_order`. Status numbers: 0 success, 1 malformed,
2 item resource limit, 3 byte admission limit, 4 execution failure. Error results
have zero sizes/consumption/digests. The adapter returns -1 for invalid batch
arguments. Prefix consumption is relative to that item's start.

Submit responses: accepted, existing, conflict, backpressure, invalid_request,
execution_failure, draining. Identical retry returns existing with sequence.
The digest is SHA-256 over the ordered concatenation, for each item, of one mode
byte (legacy=0,witness=1), one operation byte (prefix=0,exact=1), an eight-byte
little-endian input length, and the raw input bytes. Priority is admission
metadata; retrying a job never changes its priority. V1 priority is normal; v2
accepts `priority` high or normal (default normal).

Status response: `ok` with `job`, or not_found. Pending job object includes id,
digest, sequence, bytes, priority, items, and state pending or cancel_pending.
Terminal job object includes id, digest, sequence, state complete or cancelled,
and results (empty when cancelled). All integer fields are decimal strings.
Cancellation returns ok (including repeated pending cancellation), too_late, or
not_found. Shutdown returns draining and completes accepted jobs before exit.
New work during drain returns draining. Terminal events are best-effort
`{"event":"terminal","id":"job","job":{...}}` to the submitting connection,
after durable receipt. Disconnect or event loss does not alter state; status is
the recovery mechanism. The admission response precedes that connection's
terminal event. A writer/storage error must not acknowledge an uncommitted
transition; stop with diagnostics while preserving the last complete database.

Disk keys are UTF-8, with values as specified:

| Key | Value |
|---|---|
| meta/version | `1` (v2 can preserve schema 1; ABI version differs) |
| meta/sequence | Last admission sequence, decimal |
| meta/checkpoint | Contiguous terminal sequence, decimal |
| meta/jobs | Outstanding nonterminal count, decimal |
| meta/bytes | Outstanding raw payload bytes, decimal |
| id/ID | Assigned sequence, decimal |
| p/SEQ | Pending job JSON (without ephemeral state) |
| c/SEQ | `1`, durable cancellation intent |
| r/SEQ | Terminal job JSON |

SEQ is exactly 20 decimal digits padded with zeros. Absent scalar counters mean
zero only on a fresh database. Initialization writes meta/version durably. No
other version is accepted in this experiment. Pending v1 always has priority
normal; ABI v2 preserves pending priority, cancellations and receipts. JSON key
order/whitespace are not semantically meaningful. Receipt retention is unlimited
for this bounded trial. Never remove the id index when terminalizing.

Independent inspector invariants: every sequence 1..checkpoint has exactly one
receipt; every sequence checkpoint+1..sequence has exactly one pending record;
id indexes form a bijection with all jobs; cancellation keys refer only to
pending jobs; outstanding count and byte totals equal the pending sum. Receipt,
pending removal, cancel removal, checkpoint and accounting change atomically.

Build and launch contract: produce a Linux AArch64 ELF executable named `service`
at workspace root and an executable `build.sh`. Evaluator launch arguments are
`service DATADIR SOCKET_PATH`. Create/open DATADIR; fail explicitly if already
owned. SOCKET_PATH is fresh. A zero exit after draining shutdown is required.
Expose four concurrent encoding job slots; threads, tasks and ownership structure are candidate choices. The adapter performs encoding, not consensus checks.
V1 calls rn_verify_v1; v2 calls rn_verify_v2. Do not implement v2 during v1.
The evaluator observes native entrypoints externally; candidates supply no
barrier or scheduler test hooks. The runtime supplies /adapter/librosetta.so.

If native arena allocation fails during evaluate, return execution_failure. If
an already acknowledged job cannot allocate its arena, stop with diagnostics
without terminalizing it; retain its durable pending state for a later restart.
