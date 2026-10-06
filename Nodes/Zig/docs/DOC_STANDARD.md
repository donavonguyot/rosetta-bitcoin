# Zig doc standard

`//!` is the module. `///` is one declaration. Generated autodoc is
`zig build docs` into `zig-out/docs/` and is not committed.

## Module header

Every file under `src/` starts with `//!`:

1. The Bitcoin rule or node concern it owns, with BIP numbers where they apply.
2. The invariant other modules rely on.
3. Each non-obvious decision, the measurement that justified it, and the
   evidence file or ledger entry. Skip this part when there is no measurement.
4. What the module does not do.

As long as the decisions require, no longer. No measured decision means
three lines: owns, invariant, does not.

## Declaration doc

Consensus-adjacent modules (`connect`, `script`, `tx`, `block`, `codec`,
`consensus_context`, `chain_params`, `mempool`, `coins_view`, `template`,
`native_store`, `rocks_store`, `store`, `shadow_store`, `crypto*`,
`pure_secp`, `own_crypto`): every `pub fn` and every `pub const` type gets
`///` of at most four lines. Cover what it does, why Bitcoin needs it, the
invariant or precondition, and a proof: a fixture id, a `test "` name that
exists in this tree, or a gate name.

CLI modules: one `///` line on each subcommand function, naming the gate.

Private functions: no requirement. Comment only where a reader would
otherwise be wrong.

## Forbidden

Restating the signature. "This function". A TODO with no ledger entry.
Prose that a plausible refactor would make false. Paths the extraction
guard rejects (`../` doubled, `../` plus `Shared`, `/Users` plus `/`).
