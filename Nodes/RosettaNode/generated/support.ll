; Mechanical accessors. Regenerate with tools/generate_support.py.

%Scan = type { ptr, i64, i64, i64, i64, ptr, i64 }

%Write = type { ptr, i64, i64, i64 }

define internal ptr @scan_data(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 0
  %v = load ptr, ptr %p, align 1
  ret ptr %v
}
define internal void @scan_data_set(ptr %ctx, ptr %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 0
  store ptr %v, ptr %p, align 1
  ret void
}

define internal i64 @scan_len(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 1
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @scan_len_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 1
  store i64 %v, ptr %p, align 1
  ret void
}

define internal i64 @scan_pos(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 2
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @scan_pos_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 2
  store i64 %v, ptr %p, align 1
  ret void
}

define internal i64 @scan_error(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 3
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @scan_error_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 3
  store i64 %v, ptr %p, align 1
  ret void
}

define internal i64 @scan_items(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 4
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @scan_items_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 4
  store i64 %v, ptr %p, align 1
  ret void
}

define internal ptr @scan_events(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 5
  %v = load ptr, ptr %p, align 1
  ret ptr %v
}
define internal void @scan_events_set(ptr %ctx, ptr %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 5
  store ptr %v, ptr %p, align 1
  ret void
}

define internal i64 @scan_used(ptr %ctx) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 6
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @scan_used_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Scan, ptr %ctx, i32 0, i32 6
  store i64 %v, ptr %p, align 1
  ret void
}

define internal ptr @write_out(ptr %ctx) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 0
  %v = load ptr, ptr %p, align 1
  ret ptr %v
}
define internal void @write_out_set(ptr %ctx, ptr %v) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 0
  store ptr %v, ptr %p, align 1
  ret void
}

define internal i64 @write_cap(ptr %ctx) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 1
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @write_cap_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 1
  store i64 %v, ptr %p, align 1
  ret void
}

define internal i64 @write_pos(ptr %ctx) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 2
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @write_pos_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 2
  store i64 %v, ptr %p, align 1
  ret void
}

define internal i64 @write_error(ptr %ctx) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 3
  %v = load i64, ptr %p, align 1
  ret i64 %v
}
define internal void @write_error_set(ptr %ctx, i64 %v) {
entry:
  %p = getelementptr %Write, ptr %ctx, i32 0, i32 3
  store i64 %v, ptr %p, align 1
  ret void
}
