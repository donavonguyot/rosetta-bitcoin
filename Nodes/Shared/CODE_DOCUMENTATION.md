# Code Documentation Philosophy

RosettaBitcoin documentation serves two readers at once. Agents need compact
anchors that survive fast skims without bloating context. Human reviewers need
rationale, Bitcoin concepts, and language-native explanations that make each
port teachable without making it feel foreign to its ecosystem.

This is an editorial standard, not a quota or tier system. Use it to decide
where a fact belongs, how much explanation it deserves, and which source should
own it.

## Documentation Altitudes

Put each fact at the lowest-maintenance altitude that still teaches the right
thing:

| Altitude | Owns | Does not own |
|----------|------|--------------|
| Inline code docs | Local invariants, footguns, when-not-to-call notes, surprising Bitcoin semantics at the edit site | Broad tutorials, repeated contracts, status claims |
| Port architecture docs | Package map, major data flows, design tradeoffs, how this language expresses the shared Bitcoin pipeline | Live status, benchmark rankings, generated tables |

For a reusable section outline when authoring port architecture docs, see
`code-documentation/port_architecture_outline.md`.
| Shared docs | Cross-port contracts, vocabulary, proof shapes, validation order, operational boundaries | Port-specific implementation prose unless it is an example |
| Project reports | Mission-control observations and current status projections | Runtime truth used by node code |

Inline docs earn their keep at boundaries: P2P negotiation, sync orchestration,
block connection, UTXO mutation, script verification, datadir locking, status
export, Docker/proof entrypoints, and native chainstate ownership. They are
usually noise inside obvious loops, simple getters, table-shaped opcode
dispatch, or tests whose names already carry the case.

## Reader Contract

A good note helps answer at least one of these questions:

- What truth does this code own?
- What must not be broken or called too early?
- Why does Bitcoin care about this ordering or byte shape?
- Which Shared contract explains the larger rule?
- Which proof, fixture, or test would catch a regression?

Delete notes that only narrate the next line. Move anything that would become
stale after a Project import into a Project query or report.

## Canonical Vocabulary

Use these phrases consistently so agents and humans can grep across ports:

| Phrase | Meaning |
|--------|---------|
| `deferred advanced negotiation` | Delay relay-oriented messages such as `feefilter`, `mempool`, and compact-block negotiation until the node is ready for them. |
| `honest start_height` | Advertise validated height, or another conservative height, instead of claiming header tip before block validation catches up. |
| `block-local UTXO view` | Per-block spend/create view that handles same-block churn before committing durable UTXO mutations. |
| `atomic chainstate commit` | Header/block index, UTXO, undo, metadata, and validated tip move together or not at all. |
| `single-writer datadir lock` | One process owns mutable datadir state while sync/connect/rebuild is running. |
| `validation blocker` | A bounded consensus stop with enough height/tx/input/rule detail for followers to reproduce. |
| `runtime truth` | State read from the node's active chainstate backend, not Project or hand-maintained Markdown. |
| `Project projection` | Mission-control report derived from imported artifacts and observations. |

Prefer these phrases in comments and architecture docs when the concept appears.
Do not invent local synonyms unless the language or surrounding code already
uses a clear native term.

## Native Style

Every port should feel idiomatic to an expert in its language. The conceptual
spine should match across ports, but the prose and placement should not be
forced into one format.

- Python: module/function docstrings for orchestration and short comments for
  fragile state transitions.
- Java: Javadoc for public classes and methods that express node contracts;
  implementation comments for hot-loop invariants.
- TypeScript: JSDoc near exported/runtime entrypoints; short comments near
  asynchronous state transitions.
- C++: concise header comments for public surfaces; implementation comments for
  lifetime, ownership, and concurrency invariants.
- C#: XML docs for public contract surfaces; comments for storage and async
  boundaries.
- Go: package comments and exported symbol docs where Go tooling expects them.
- Rust: `//!` module docs for conceptual modules and `///` on public surfaces.
- OCaml: top-level `.mli` or module comments where useful; avoid prose inside
  obvious pattern matches.
- Elixir: `@moduledoc` and `@doc` for public modules/functions unless the
  module is intentionally private and simple.
- Swift: doc comments on public types/functions and short notes for memory or
  concurrency-sensitive code.
- Zig: top-level comments for files that own protocol or storage boundaries,
  plus compact notes near comptime or byte-layout traps.

See `code-documentation/language_idioms.md` for examples.

## What Not To Do

- Do not create a hard tier system or permanent file inventory.
- Do not add comment-density tooling.
- Do not restate Project status, benchmark rank, lifecycle status, or binary
  gate posture in inline code comments.
- Do not duplicate a Shared contract in a source file. Link to the contract and
  explain the local invariant.
- Do not add long Bitcoin tutorials inline. Put teaching material in Shared or
  port architecture docs.
- Do not make every port sound identical. Make every port teach the same
  Bitcoin pipeline in its own language.

## Agent Workflow

Use ephemeral briefs for documentation passes. A lead agent should name the
small surface, the relevant Shared docs, the vocabulary to preserve, and the
files to inspect in that moment. The brief expires with the batch; it is not a
permanent work queue.

Before accepting a documentation batch, review it with
`code-documentation/review_questions.md`. Run `Project/scripts/check_doc_drift.py`
after Markdown edits and use grep to confirm the canonical vocabulary creates
useful anchors without comment spam.
