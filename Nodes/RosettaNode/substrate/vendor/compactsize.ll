; Bounds are checked by the caller before this internal little-endian reader.
define internal i64 @read_le(ptr %data, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %acc = phi i64 [ 0, %entry ], [ %combined, %loop ]
  %p = getelementptr i8, ptr %data, i64 %i
  %b = load i8, ptr %p, align 1
  %v = zext i8 %b to i64
  %shift = mul i64 %i, 8
  %shifted = shl i64 %v, %shift
  %combined = or i64 %acc, %shifted
  %next = add i64 %i, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %combined
}

define i32 @cs_decode(ptr %data, i64 %len, ptr %value, ptr %consumed) {
entry:
  %empty = icmp eq i64 %len, 0
  br i1 %empty, label %truncated, label %tag
 tag:
  %first = load i8, ptr %data, align 1
  %small = icmp ult i8 %first, -3
  br i1 %small, label %one, label %wide
one:
  %single = zext i8 %first to i64
  br label %success
wide:
  switch i8 %first, label %eight [ i8 -3, label %two
                                  i8 -2, label %four ]
two:
  br label %payload
four:
  br label %payload
eight:
  br label %payload
payload:
  %n = phi i64 [ 2, %two ], [ 4, %four ], [ 8, %eight ]
  %minimum = phi i64 [ 253, %two ], [ 65536, %four ], [ 4294967296, %eight ]
  %remaining = sub i64 %len, 1
  %fits = icmp ule i64 %n, %remaining
  br i1 %fits, label %read, label %truncated
read:
  %start = getelementptr i8, ptr %data, i64 1
  %decoded = call i64 @read_le(ptr %start, i64 %n)
  %canonical = icmp uge i64 %decoded, %minimum
  br i1 %canonical, label %accepted, label %noncanonical
accepted:
  %width = add i64 %n, 1
  br label %success
success:
  %result = phi i64 [ %single, %one ], [ %decoded, %accepted ]
  %used = phi i64 [ 1, %one ], [ %width, %accepted ]
  store i64 %result, ptr %value, align 1
  store i64 %used, ptr %consumed, align 1
  ret i32 0
truncated:
  ret i32 1
noncanonical:
  ret i32 2
}

define i32 @cs_encode(i64 %value, ptr %out, i64 %capacity, ptr %consumed) {
entry:
  %small = icmp ult i64 %value, 253
  %u16 = icmp ule i64 %value, 65535
  %u32 = icmp ule i64 %value, 4294967295
  %large_n = select i1 %u32, i64 4, i64 8
  %wide_n = select i1 %u16, i64 2, i64 %large_n
  %n = select i1 %small, i64 0, i64 %wide_n
  %need = add i64 %n, 1
  %fits = icmp ule i64 %need, %capacity
  br i1 %fits, label %write, label %short
write:
  %v8 = trunc i64 %value to i8
  %large_tag = select i1 %u32, i8 -2, i8 -1
  %wide_tag = select i1 %u16, i8 -3, i8 %large_tag
  %tag = select i1 %small, i8 %v8, i8 %wide_tag
  store i8 %tag, ptr %out, align 1
  br i1 %small, label %done, label %loop
loop:
  %i = phi i64 [ 0, %write ], [ %next, %loop ]
  %shift = mul i64 %i, 8
  %shifted = lshr i64 %value, %shift
  %byte = trunc i64 %shifted to i8
  %next = add i64 %i, 1
  %p = getelementptr i8, ptr %out, i64 %next
  store i8 %byte, ptr %p, align 1
  %finished = icmp eq i64 %next, %n
  br i1 %finished, label %done, label %loop
done:
  store i64 %need, ptr %consumed, align 1
  ret i32 0
short:
  ret i32 1
}
