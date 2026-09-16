# RosettaNode transaction encoding profile v1

This is an experimental encoding specification, not consensus validation. The caller selects legacy or witness mode. Versions preserve 32 raw bits as unsigned `version_bits`; amounts preserve signed 64-bit values, including negative amounts. Neither interpretation makes a transaction valid.

TX-1. Read version, then the first input vector. In witness mode only, an empty first vector is followed by one flags byte. If flags is zero, omit output-vector reading and read locktime next. If flags is nonzero, read another input vector and the output vector. Otherwise read the ordinary output vector. A nonempty first vector never introduces flags.

TX-2. If bit 0 is set, read one witness stack per input and clear bit 0. At least one stack must contain an item; a single empty item counts. All stacks with zero items are a superfluous witness encoding. Reject remaining flag bits. Read locktime after optional-data checks. Unknown flags and superfluous witness are malformed encoding, not consensus verdicts.

TX-3. Every CompactSize is canonical. Input records require at least 41 encoded bytes; outputs at least 9; witness items at least 1. Check advertised counts against remaining bytes divided by these minima before iteration. Scripts are opaque. All variable iterations consume bytes. Complete a constant-scratch forward structural scan before materializing objects. Never allocate according to an unchecked count.

TX-4. Admission is at most 4 MiB of bytes beginning at the caller's offset. Offsets outside the supplied bytes are invalid requests. Consumption is relative to the offset. Exact decoding rejects trailing bytes before applying the combined input/output/witness-item budget, default 4096. Continue scanning beyond that budget: impossible counts or truncation remain malformed; a complete over-budget object is resource_limit. Failures leave the caller's cursor unchanged and expose no partial object. Allocation failure is execution_failure. Transport separately limits decoded bytes to 8 MiB and JSON request text to 20 MiB; these are harness limits, not Bitcoin rules.

TX-5. Structured serialization takes field values, without requiring original bytes. Emit marker zero and flags one only when include_witness is true and some stack contains an item. Stripped serialization always omits witness. The same structure must produce the same bytes irrespective of decode history. Empty-input structures can serialize to bytes whose witness-mode interpretation differs; no unconditional decode/serialize inverse is promised. Witness encoding decoded in legacy mode also has different meaning.

TX-6. Identify uses SHA-256 twice on each serialization. txid uses stripped bytes; wtxid uses full bytes. Return both direct digest byte order and reversed display byte order with explicitly different names. Report full and stripped byte sizes; weight is excluded.

Provenance: Bitcoin Core v28.2 src/primitives/transaction.h serialization state machine; src/serialize.h CompactSize; BIP141 and BIP144. Resource/cursor/error precedence is this experimental profile and can differ from Core/btcd. Independently justified synthetic fixtures and valid-chain commitments constrain different parts of this contract.

## Field layout and request interpretation

A basic encoding consists of version (4 bytes), input count (CompactSize), input records, output count (CompactSize), output records, and locktime (4 bytes). All multi-byte integers are little endian. An input is 32 transaction digest bytes, a 4-byte previous output index, CompactSize script length, script bytes, and 4-byte sequence. An output is an 8-byte two's-complement amount, CompactSize script length, and script bytes. A witness stack is CompactSize item count, then CompactSize length and bytes for each item. CompactSize rules are defined in the preceding chapter.

version_bits, previous_index, sequence, and locktime must be in 0 through 4294967295. Amounts range from -9223372036854775808 through 9223372036854775807. Previous transaction digests contain exactly 32 bytes in digest order. Decimal strings have no leading zeroes except zero itself and no plus sign. Uppercase or lowercase input hex is accepted; emitted hex is lowercase. Structured transaction field sets are exact; extra request-envelope fields are ignored. Invalid shapes/ranges and invalid offsets return invalid_request. Mode is required for decoding; prefix offset defaults to zero. The limit may be lowered from 4096 but not increased.

For this experiment serialized output is also capped at 4 MiB; an otherwise correctly shaped over-envelope structure returns resource_limit. Structured-input marshaling validates its field types and ranges before the item-budget verdict. The transport budget applies to the aggregate structured byte pool as well as decoded request bytes. These are experiment envelope choices, not Bitcoin validity rules.

Decode errors return status only, with neither a partial transaction nor a consumed field. No operation performs signature, value-conservation, script, transaction-version, or block validity checks. Size means encoded byte count. Hash digest order is the 32 bytes returned by double SHA-256; display order is that byte string reversed.

## Executable definitions

```llvm module=transactions
; Literal authored transaction state machine. Accessors are mechanical support.

define internal i1 @bad(ptr %s) {
entry:
  %e = call i64 @scan_error(ptr %s)
  %b = icmp ne i64 %e, 0
  ret i1 %b
}

define internal i64 @take(ptr %s, i64 %n) {
entry:
  %p = call i64 @scan_pos(ptr %s)
  %len = call i64 @scan_len(ptr %s)
  %remain = sub i64 %len, %p
  %fits = icmp ule i64 %n, %remain
  %failed = call i1 @bad(ptr %s)
  %clean = xor i1 %failed, true
  %ok = and i1 %fits, %clean
  br i1 %ok, label %accept, label %reject
accept:
  %next = add i64 %p, %n
  call void @scan_pos_set(ptr %s, i64 %next)
  ret i64 %p
reject:
  call void @scan_error_set(ptr %s, i64 1)
  ret i64 0
}

define internal i64 @number(ptr %s, i64 %n) {
entry:
  %p = call i64 @take(ptr %s, i64 %n)
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %reject, label %read
read:
  %data = call ptr @scan_data(ptr %s)
  %start = getelementptr i8, ptr %data, i64 %p
  %value = call i64 @read_le(ptr %start, i64 %n)
  ret i64 %value
reject:
  ret i64 0
}

define internal i64 @compact(ptr %s) {
entry:
  %v = alloca i64
  %u = alloca i64
  store i64 0, ptr %v
  store i64 0, ptr %u
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %reject, label %read
read:
  %data = call ptr @scan_data(ptr %s)
  %p = call i64 @scan_pos(ptr %s)
  %len = call i64 @scan_len(ptr %s)
  %remaining = sub i64 %len, %p
  %start = getelementptr i8, ptr %data, i64 %p
  %status = call i32 @cs_decode(ptr %start, i64 %remaining, ptr %v, ptr %u)
  %ok = icmp eq i32 %status, 0
  br i1 %ok, label %accept, label %reject
accept:
  %used = load i64, ptr %u
  %next = add i64 %p, %used
  call void @scan_pos_set(ptr %s, i64 %next)
  %value = load i64, ptr %v
  ret i64 %value
reject:
  call void @scan_error_set(ptr %s, i64 1)
  ret i64 0
}

define internal void @event(ptr %s, i64 %kind, i64 %a, i64 %b, i64 %c) {
entry:
  %n = call i64 @scan_used(ptr %s)
  %next = add i64 %n, 1
  call void @scan_used_set(ptr %s, i64 %next)
  %events = call ptr @scan_events(ptr %s)
  %has = icmp ne ptr %events, null
  br i1 %has, label %write, label %done
write:
  %index = mul i64 %n, 4
  %p = getelementptr i64, ptr %events, i64 %index
  store i64 %kind, ptr %p, align 1
  %pa = getelementptr i64, ptr %p, i64 1
  %pb = getelementptr i64, ptr %p, i64 2
  %pc = getelementptr i64, ptr %p, i64 3
  store i64 %a, ptr %pa, align 1
  store i64 %b, ptr %pb, align 1
  store i64 %c, ptr %pc, align 1
  br label %done
done:
  ret void
}

define internal i1 @count_fits(ptr %s, i64 %n, i64 %minimum) {
entry:
  %p = call i64 @scan_pos(ptr %s)
  %len = call i64 @scan_len(ptr %s)
  %remaining = sub i64 %len, %p
  %max = udiv i64 %remaining, %minimum
  %fits = icmp ule i64 %n, %max
  br i1 %fits, label %yes, label %no
yes:
  %old = call i64 @scan_items(ptr %s)
  %next = add i64 %old, %n
  call void @scan_items_set(ptr %s, i64 %next)
  ret i1 true
no:
  call void @scan_error_set(ptr %s, i64 1)
  ret i1 false
}

define internal void @inputs(ptr %s, i64 %count) {
entry:
  call void @event(ptr %s, i64 7, i64 %count, i64 0, i64 0)
  %fits = call i1 @count_fits(ptr %s, i64 %count, i64 41)
  br i1 %fits, label %loop, label %done
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %item ]
  %more = icmp ult i64 %i, %count
  br i1 %more, label %item, label %done
item:
  %prev = call i64 @take(ptr %s, i64 32)
  %index = call i64 @number(ptr %s, i64 4)
  %size = call i64 @compact(ptr %s)
  %script = call i64 @take(ptr %s, i64 %size)
  %sequence = call i64 @number(ptr %s, i64 4)
  call void @event(ptr %s, i64 1, i64 %prev, i64 %sequence, i64 %index)
  call void @event(ptr %s, i64 2, i64 %script, i64 %size, i64 %sequence)
  %next = add i64 %i, 1
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %done, label %loop
done:
  ret void
}

define internal void @outputs(ptr %s) {
entry:
  %count = call i64 @compact(ptr %s)
  call void @event(ptr %s, i64 8, i64 %count, i64 0, i64 0)
  %fits = call i1 @count_fits(ptr %s, i64 %count, i64 9)
  br i1 %fits, label %loop, label %done
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %item ]
  %more = icmp ult i64 %i, %count
  br i1 %more, label %item, label %done
item:
  %amount = call i64 @number(ptr %s, i64 8)
  %size = call i64 @compact(ptr %s)
  %script = call i64 @take(ptr %s, i64 %size)
  call void @event(ptr %s, i64 3, i64 %amount, i64 %script, i64 %size)
  %next = add i64 %i, 1
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %done, label %loop
done:
  ret void
}

define internal i1 @witness(ptr %s, i64 %count) {
entry:
  br label %stack
stack:
  %i = phi i64 [ 0, %entry ], [ %next, %stack_done ]
  %has = phi i1 [ false, %entry ], [ %found, %stack_done ]
  %more = icmp ult i64 %i, %count
  br i1 %more, label %read_stack, label %done
read_stack:
  %n = call i64 @compact(ptr %s)
  call void @event(ptr %s, i64 4, i64 %n, i64 0, i64 0)
  %some = icmp ne i64 %n, 0
  %found = or i1 %has, %some
  %fits = call i1 @count_fits(ptr %s, i64 %n, i64 1)
  br i1 %fits, label %item_loop, label %reject
item_loop:
  %j = phi i64 [ 0, %read_stack ], [ %jnext, %item ]
  %item_more = icmp ult i64 %j, %n
  br i1 %item_more, label %item, label %stack_done
item:
  %size = call i64 @compact(ptr %s)
  %data = call i64 @take(ptr %s, i64 %size)
  call void @event(ptr %s, i64 5, i64 %data, i64 %size, i64 0)
  %jnext = add i64 %j, 1
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %reject, label %item_loop
stack_done:
  %next = add i64 %i, 1
  br label %stack
reject:
  ret i1 false
done:
  ret i1 %has
}

; Caller supplies initialized context; event buffer is null on the first scan.
; Status: 0 success, 1 malformed, 2 resource. No allocation occurs here.
define i64 @tx_scan(ptr %s, i1 %allow_witness, i1 %exact, i64 %budget) {
entry:
  %version = call i64 @number(ptr %s, i64 4)
  call void @event(ptr %s, i64 0, i64 %version, i64 0, i64 0)
  %first = call i64 @compact(ptr %s)
  %empty = icmp eq i64 %first, 0
  %optional = and i1 %empty, %allow_witness
  br i1 %optional, label %flags, label %ordinary
ordinary:
  call void @inputs(ptr %s, i64 %first)
  call void @outputs(ptr %s)
  br label %lock
flags:
  %flag = call i64 @number(ptr %s, i64 1)
  %zero = icmp eq i64 %flag, 0
  br i1 %zero, label %zero_flags, label %extended
zero_flags:
  call void @event(ptr %s, i64 7, i64 0, i64 0, i64 0)
  call void @event(ptr %s, i64 8, i64 0, i64 0, i64 0)
  br label %lock
extended:
  %second = call i64 @compact(ptr %s)
  call void @inputs(ptr %s, i64 %second)
  call void @outputs(ptr %s)
  %bit = and i64 %flag, 1
  %wit = icmp ne i64 %bit, 0
  br i1 %wit, label %read_witness, label %check_flags
read_witness:
  %has = call i1 @witness(ptr %s, i64 %second)
  br i1 %has, label %check_flags, label %malformed
check_flags:
  %unknown = and i64 %flag, -2
  %known = icmp eq i64 %unknown, 0
  br i1 %known, label %lock, label %malformed
lock:
  %locktime = call i64 @number(ptr %s, i64 4)
  call void @event(ptr %s, i64 6, i64 %locktime, i64 0, i64 0)
  %failed = call i1 @bad(ptr %s)
  br i1 %failed, label %malformed, label %tail
tail:
  %pos = call i64 @scan_pos(ptr %s)
  %len = call i64 @scan_len(ptr %s)
  %trailing = icmp ne i64 %pos, %len
  %reject_tail = and i1 %exact, %trailing
  br i1 %reject_tail, label %malformed, label %resource
resource:
  %items = call i64 @scan_items(ptr %s)
  %over = icmp ugt i64 %items, %budget
  %status = select i1 %over, i64 2, i64 0
  ret i64 %status
malformed:
  ret i64 1
}
define internal void @write_bytes(ptr %w, ptr %source, i64 %n) {
entry:
  %pos = call i64 @write_pos(ptr %w)
  %cap = call i64 @write_cap(ptr %w)
  %remain = sub i64 %cap, %pos
  %fits = icmp ule i64 %n, %remain
  br i1 %fits, label %accept, label %reject
accept:
  %out = call ptr @write_out(ptr %w)
  %materialize = icmp ne ptr %out, null
  br i1 %materialize, label %loop, label %advance
loop:
  %i = phi i64 [ 0, %accept ], [ %next, %copy ]
  %more = icmp ult i64 %i, %n
  br i1 %more, label %copy, label %advance
copy:
  %src = getelementptr i8, ptr %source, i64 %i
  %value = load i8, ptr %src, align 1
  %index = add i64 %pos, %i
  %dst = getelementptr i8, ptr %out, i64 %index
  store i8 %value, ptr %dst, align 1
  %next = add i64 %i, 1
  br label %loop
advance:
  %end = add i64 %pos, %n
  call void @write_pos_set(ptr %w, i64 %end)
  ret void
reject:
  call void @write_error_set(ptr %w, i64 2)
  ret void
}

define internal void @write_number(ptr %w, i64 %value, i64 %n) {
entry:
  %bytes = alloca [8 x i8]
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %item ]
  %more = icmp ult i64 %i, %n
  br i1 %more, label %item, label %done
item:
  %shift = mul i64 %i, 8
  %shifted = lshr i64 %value, %shift
  %byte = trunc i64 %shifted to i8
  %p = getelementptr i8, ptr %bytes, i64 %i
  store i8 %byte, ptr %p, align 1
  %next = add i64 %i, 1
  br label %loop
done:
  call void @write_bytes(ptr %w, ptr %bytes, i64 %n)
  ret void
}

define internal void @write_compact(ptr %w, i64 %value) {
entry:
  %bytes = alloca [9 x i8]
  %used = alloca i64
  store i64 0, ptr %used
  %status = call i32 @cs_encode(i64 %value, ptr %bytes, i64 9, ptr %used)
  %n = load i64, ptr %used
  call void @write_bytes(ptr %w, ptr %bytes, i64 %n)
  ret void
}

; Normalized events are validated by the ABI marshaler, not raw peer data.
; The byte pool contains only script, outpoint, and witness payloads.
define i64 @tx_serialize(ptr %events, i64 %count, ptr %pool, i1 %include, ptr %w) {
entry:
  br label %survey
survey:
  %j = phi i64 [ 0, %entry ], [ %jnext, %survey_item ]
  %has = phi i1 [ false, %entry ], [ %found, %survey_item ]
  %more = icmp ult i64 %j, %count
  br i1 %more, label %survey_item, label %begin
survey_item:
  %idx = mul i64 %j, 4
  %ep = getelementptr i64, ptr %events, i64 %idx
  %kind0 = load i64, ptr %ep, align 1
  %ap = getelementptr i64, ptr %ep, i64 1
  %a0 = load i64, ptr %ap, align 1
  %stack = icmp eq i64 %kind0, 4
  %nonempty = icmp ne i64 %a0, 0
  %some = and i1 %stack, %nonempty
  %found = or i1 %has, %some
  %jnext = add i64 %j, 1
  br label %survey
begin:
  %extended = and i1 %has, %include
  br label %loop
loop:
  %i = phi i64 [ 0, %begin ], [ %next, %advance ]
  %active = icmp ult i64 %i, %count
  br i1 %active, label %load, label %done
load:
  %index = mul i64 %i, 4
  %p = getelementptr i64, ptr %events, i64 %index
  %kind = load i64, ptr %p, align 1
  %pa = getelementptr i64, ptr %p, i64 1
  %pb = getelementptr i64, ptr %p, i64 2
  %pc = getelementptr i64, ptr %p, i64 3
  %a = load i64, ptr %pa, align 1
  %b = load i64, ptr %pb, align 1
  %c = load i64, ptr %pc, align 1
  switch i64 %kind, label %invalid [
    i64 0, label %version
    i64 1, label %input
    i64 2, label %script
    i64 3, label %output
    i64 4, label %stack_count
    i64 5, label %witness_item
    i64 6, label %locktime
    i64 7, label %vector_count
    i64 8, label %vector_count
  ]
version:
  call void @write_number(ptr %w, i64 %a, i64 4)
  br i1 %extended, label %marker, label %advance
marker:
  call void @write_number(ptr %w, i64 256, i64 2)
  br label %advance
input:
  %prev = getelementptr i8, ptr %pool, i64 %a
  call void @write_bytes(ptr %w, ptr %prev, i64 32)
  call void @write_number(ptr %w, i64 %c, i64 4)
  br label %advance
script:
  call void @write_compact(ptr %w, i64 %b)
  %scriptdata = getelementptr i8, ptr %pool, i64 %a
  call void @write_bytes(ptr %w, ptr %scriptdata, i64 %b)
  call void @write_number(ptr %w, i64 %c, i64 4)
  br label %advance
output:
  call void @write_number(ptr %w, i64 %a, i64 8)
  call void @write_compact(ptr %w, i64 %c)
  %outscript = getelementptr i8, ptr %pool, i64 %b
  call void @write_bytes(ptr %w, ptr %outscript, i64 %c)
  br label %advance
stack_count:
  br i1 %extended, label %vector_count, label %advance
vector_count:
  call void @write_compact(ptr %w, i64 %a)
  br label %advance
witness_item:
  br i1 %extended, label %witness_data, label %advance
witness_data:
  call void @write_compact(ptr %w, i64 %b)
  %witdata = getelementptr i8, ptr %pool, i64 %a
  call void @write_bytes(ptr %w, ptr %witdata, i64 %b)
  br label %advance
locktime:
  call void @write_number(ptr %w, i64 %a, i64 4)
  br label %advance
advance:
  %next = add i64 %i, 1
  br label %loop
invalid:
  call void @write_error_set(ptr %w, i64 3)
  br label %done
done:
  %error = call i64 @write_error(ptr %w)
  ret i64 %error
}

; SHA implementation is a pinned native primitive; composition belongs to IR.
declare i32 @rn_sha256(ptr, i64, ptr)
define i32 @tx_digest(ptr %data, i64 %len, ptr %digest) {
entry:
  %first = alloca [32 x i8]
  %a = call i32 @rn_sha256(ptr %data, i64 %len, ptr %first)
  %ok = icmp eq i32 %a, 1
  br i1 %ok, label %second, label %failure
second:
  %b = call i32 @rn_sha256(ptr %first, i64 32, ptr %digest)
  ret i32 %b
failure:
  ret i32 0
}
```
