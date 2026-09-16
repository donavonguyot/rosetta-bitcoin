# Paused experiment checkpoint

The user paused all agent work for cost review on 2026-09-16. No resumption is
authorized. `pause.json` supersedes stale live controller phase labels for this
checkpoint without changing any frozen experiment record.

All six initial and six maintenance rounds qualified under semantic evaluator
v2. Zig-1 optimization qualified. Go-1 and Rust-1 optimization were interrupted;
the other three optimization rounds never started. No final serial performance
campaign or substrate recommendation was completed.

## Preserved source

`source-index.json` maps original repository-relative paths to SHA-256-named text
files in `objects/`. Identical content is stored once. This includes transfer
attempts, substrate initial/repair/maintenance submissions, meaningful local
variants, and interrupted workspaces. A workspace snapshot is not a qualified
submission. Original submission hashes and evidence determine that distinction.
Runtime JSON dumps, executable binaries, databases and caches are not source.

Restore an original directory into a new directory with:

```sh
python3 Nodes/RosettaNode/substrate/checkpoints/restore.py ORIGINAL_DIRECTORY NEW_DIRECTORY
```

Choose ORIGINAL_DIRECTORY from the index. Restoration verifies every digest,
refuses existing destinations and preserves executable permissions for scripts.
Toolchains and dependency inputs remain local/pinned; no model calls are needed.

## Local retention and cleanup

`local-retention.json` records the verified compressed diagnostic archive and
its hash, the local file inventory, and exact compiler-cache removals. The
archive contains original transcripts and diagnostics; raw copies remain so
existing evidence paths still resolve. Runtime datadirs, failed-run volumes,
Docker images, toolchain downloads and standalone dependency stores were not
removed. Local archives are not a remote backup.

`capture.py` records the one-time preservation procedure. Its fixed archive
location intentionally prevents accidental reruns. Monetary cost and unfinished
phase token totals are unknown where the runner did not report them. No prices
or missing usage are inferred.

The final cleanup report is `verification.json`. This is a preservation
checkpoint, not a new experiment, benchmark or readiness claim.
