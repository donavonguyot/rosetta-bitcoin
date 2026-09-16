# Infrastructure reuse boundary

These are newly prepared infrastructure slices, not copied node services. Every
language receives the same capabilities and storage settings. No scheduling,
job schema, transaction logic, journaling policy or service implementation is
provided. Bindings call the designated dynamic RocksDB C API. `rocksdb_open`
holds RocksDB's native exclusive datadir LOCK until `rocksdb_close`; a second
writer must fail. Read only after the writer stops when independently inspecting.

Candidate workspaces receive the common C adapter header and shared library at
`/adapter/adapter.h` and `/adapter/librosetta.so` inside the Linux build broker.
Link with `-L/adapter -lrosetta -Wl,-rpath,/adapter` and `-lrocksdb`. Do not copy or
replace the kernel. Keep input arenas alive until worker calls return.

The runtime includes all toolchains and offline documentation:

- Go: `/opt/go/doc/go_spec.html`, `/opt/go/doc/go_mem.html`, `/opt/go/src` and
  `go doc` for standard-library package documentation.
- Rust: `/opt/rust/share/doc/rust/html` including the Book and standard library.
  Pinned serde/serde_json/libc sources and Cargo.lock are supplied offline.
- Zig: `/opt/zig/doc/langref.html` and `/opt/zig/lib/std`; use the shipped library
  source comments for precise 0.16 APIs. No prescribed I/O architecture.
- RocksDB: `/usr/include/rocksdb/c.h`, pinned 7.8.3-2, is the authoritative C API.

The per-language examples have identical open/read/WriteBatch/sync/locking
capabilities. Copies and ownership inside wrappers are visible and may be
changed by candidates while preserving the C API and runtime settings. Helpers
are not a performance reference. Preparation time and unknown usage are reported
separately from candidate implementation time.
