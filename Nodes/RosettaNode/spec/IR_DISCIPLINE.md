# IR and ABI discipline

Authored IR has no mutable globals, undef, poison, inbounds, nsw or nuw. All
byte loads use alignment 1. Native target/layout come from toolchain.json and
are supplied when composing the extracted modules. LLVM verify/lint run before
compilation. Checked disposable modules add sanitize_address attributes before
Clang's ASan pipeline; instrumenting only the C caller is insufficient.

The scanner context starts with data, admitted length, cursor zero, error zero,
item count zero, null event buffer and event count zero. take checks n against
length minus cursor before advancing. number only loads after take succeeds.
compact delegates to the checked canonical primitive. count_fits uses division
before iteration. No unchecked advertised vector count drives a loop. All
vector/item progress consumes bytes, bounding work by the admitted suffix.

The first pass has constant scratch space and no materialized transaction.
After framing/exactness and item-budget success, the adapter allocates precisely
the event count times 32 bytes and repeats the deterministic scan. Event fields
are copied into the JSON object without retaining a raw-serialization shortcut.
The event sink is an internal trusted ABI, not a public untrusted pointer API.
Its capacity is the successful first-pass count. Caller buffers are immutable
between scans. Admission bounds make internal event/item sums non-overflowing.

Serialization receives a shape/range-validated event tape and byte pool from
the marshaler. The first writer pass sizes with a null output; the second has
exact capacity. write_bytes checks subtraction-based bounds before stores.
write_number uses only fixed widths 1/2/4/8; shifts remain below 64. Hashing calls
a native SHA primitive twice from IR. Display-order reversal belongs to JSON
presentation. No consensus decision is delegated to the host because this slice
contains no consensus-validation operation.

Coverage counters exist only in disposable copies. They are inserted after phi
groups and mapped to authored symbol/block identifiers. C counter globals do not
ship in the reference. Reachability is not path completeness; failures for
trusted ABI misuse and native SHA failure remain explicit coverage gaps.
