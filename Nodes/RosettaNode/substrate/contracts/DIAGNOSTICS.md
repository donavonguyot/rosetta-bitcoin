# Diagnostic coverage (proposed; freeze only after demonstrating support)

| Lane | Coverage | Excluded claim |
|---|---|---|
| Native ASan | Instrumented adapter, IR, arena | Native RocksDB and whole-service race freedom |
| Go race + cgo | Instrumented Go paths | C/C++ library races |
| Rust | Compiler checks, demonstrated native diagnostics | Miri across FFI; whole-service TSan |
| Zig | Checked builds, allocator/native diagnostics | Equivalence to Go race detection |
| External concurrency/crash | Observable histories and recovered database | Exhaustive memory/race proof; power loss |

Unsupported lanes remain visible. Extra diagnostics require demonstrated pinned
preparation before freeze. Process-crash recovery is the durability boundary.
