# Zig node tests

Run `zig build test` with Zig 0.16.0. The suite exercises the core library,
native store, mempool/template logic, and consensus context. Run store modes
with `-Dstore=both`, `rocksdb`, and `native`; select experimental crypto with
`-Dcrypto-backend=own_curve`.

Tests consume frozen fixture bytes and fail if required inputs are absent.
The standalone export bundles them; `-Dfixtures-root` overrides their location.
Documentation coverage is informational and writes under `zig-out/`.
`python3 scripts/test_doc_coverage.py` checks that nested worktrees do not affect
coverage or the external-path guard.

CLI checks include `script-corpus`, `consensus-context`, `codec-vectors`, and
`test-capability --kind crypto-vectors`. See the [README](../README.md) for
standalone commands and separate lab proof targets.
