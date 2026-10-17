# Contributing to Zigibit

Start with [build and test instructions](README.md) and the
[architecture map](docs/ARCHITECTURE.md). Use a branch and isolated state outside
source. Until extraction is explicitly completed, RosettaBitcoin owns the
canonical node source; do not establish a competing repository or mirror.

For a change, explain the observed problem, resulting behavior, affected
storage/crypto lanes, and verification. Consensus fixes need a reproducing frozen
fixture with the exact rule and blocker facts. Do not regenerate expected bytes
to make a test pass. Reject unsupported rules rather than assuming validity.

Run `zig build test -Doptimize=ReleaseSafe` and `zig build docs`. For changes
across backends, also run `zig build test -Doptimize=ReleaseSafe -Dstore=native
-Dcrypto-backend=own_curve` (as one command). The complete CI entrypoint is
`scripts/ci_standalone.py`; it requires a matching source inventory, as described
in the README. Record skipped cases as skips, not passes.

Keep implementation edits separate from evidence promotion. Commit source,
tests, documentation, and frozen fixtures; exclude generated output, databases,
credentials, and live state. Security-sensitive findings follow
[SECURITY.md](SECURITY.md). Dependency changes follow
[DEPENDENCIES.md](docs/DEPENDENCIES.md).

RB owns Reference topology, capture/stimulus tooling, benchmark orchestration,
Project imports, and historical campaign records. Its
[consumer cutover guide](https://github.com/donavonguyot/rosetta-bitcoin/blob/main/Docs/zigibit-consumers.md)
explains how the lab consumes an external inventory. A source move does not
transfer benchmark claims or authorize deferred experiments.
