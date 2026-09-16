# Candidate workspace

Use `python3 run.py 'COMMAND'` for builds, tests and offline documentation. This
executes inside the pinned Linux AArch64 container with this workspace at
`/workspace`, the read-only adapter at `/adapter`, and no network. For longer
builds, pass a second argument up to 300 seconds. Do not use host toolchains,
Docker, external networks or source outside this workspace. No evaluator or
other candidate is mounted in the build container.

Deliver `build.sh`, executable `service`, source, your tests and `HANDOFF.md`.
Record hypotheses and failed experiments in `EXPERIMENTS.md`; optimization permits
at most three hypotheses including group commit. Do not replace the LLVM kernel
or weaken durability. Reuse helpers are optional infrastructure, not a service.
The standard library docs live at the paths in README.md. Finish early when ready.

Examples of linking the common adapter:

- Go: cgo directives `#cgo CFLAGS: -I/adapter` and
  `#cgo LDFLAGS: -L/adapter -lrosetta -Wl,-rpath,/adapter -lrocksdb`.
  CGO_ENABLED=1; gcc is available. Native arenas are not retained Go pointers.
- Rust: external C declarations, `#[link(name="rosetta")]`, and linker flags
  `-L native=/adapter -C link-arg=-Wl,-rpath,/adapter`. Pinned serde/libc Cargo
  assets are in the offline Cargo cache; preserve their versions/checksums.
- Zig: C import of `/adapter/adapter.h`, link `-lc -lrosetta -lrocksdb`,
  `-I/adapter -I/usr/include -L/adapter -L/usr/lib/aarch64-linux-gnu`
  and `-rpath /adapter`. Standard-library and libc infrastructure are allowed.

Run `python3 public_check.py ./service` inside the broker for a small smoke test.
It does not prove crash recovery, concurrency correctness or full acceptance.
