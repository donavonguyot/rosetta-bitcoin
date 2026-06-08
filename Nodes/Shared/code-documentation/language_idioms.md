# Language Idioms For Code Documentation

The same Bitcoin pipeline should be recognizable in every port, but the docs
should feel native to the language being read.

## Python

- Use module docstrings for modules that own orchestration or storage boundaries.
- Use function docstrings for public CLI/service entrypoints.
- Use short inline comments for event-loop ordering and state transitions.
- Avoid docstrings on tiny helpers where the function name is enough.

## Java

- Use Javadoc on public classes and methods that express runtime contracts.
- Put implementation comments immediately above hot-loop invariants.
- Prefer concrete nouns over abstract prose: `validated tip`, `UTXO`, `undo`,
  `block index`, `datadir lock`.
- Keep status language out of Javadoc; link to Project queries in Markdown docs.

## TypeScript

- Use JSDoc on exported classes/functions and async lifecycle transitions.
- Keep comments close to the `await` or status transition that creates the
  ordering hazard.
- Use exact wire command names such as `feefilter`, `mempool`, and `sendheaders`.

## C++

- Use header comments for public ownership/lifetime contracts.
- Use implementation comments for concurrency, lock, and hot-path ordering.
- Keep comments short enough that they do not obscure control flow.

## C#

- Use XML docs for public contract surfaces and CLI/service entrypoints.
- Use normal comments for internal invariants around RocksDB, lock ownership,
  and script verification.

## Go

- Use package comments where the package owns a Bitcoin concept.
- Document exported symbols in the standard Go style.
- Avoid block comments in hot loops unless they explain an invariant.

## Rust

- Use `//!` module docs for modules such as `p2p`, `connect`, `storage`, and
  `script_verify`.
- Use `///` on public functions/types that encode Bitcoin or chainstate
  contracts.
- Prefer precise lifetime/ownership notes over broad tutorial prose.

## OCaml

- Prefer module-level comments and `.mli` surface docs when available.
- Use short comments for byte-layout, parser, and RocksDB ownership boundaries.
- Avoid commentary on straightforward pattern matching.

## Elixir

- Use `@moduledoc` for modules that teach a Bitcoin concept or runtime boundary.
- Use `@doc` for public functions called by CLI/supervisor paths.
- Keep `@moduledoc false` for intentionally private plumbing only.

## Swift

- Use Swift doc comments for public types and functions.
- Call out consensus byte-order and memory/lifetime assumptions near the API
  surface that exposes them.

## Zig

- Use top-level file comments for modules that own protocol, storage, or proof
  boundaries.
- Add compact comments near byte-layout, allocator lifetime, and comptime traps.
- Avoid prose inside obvious serialization append sequences unless consensus
  byte order would be easy to invert.
