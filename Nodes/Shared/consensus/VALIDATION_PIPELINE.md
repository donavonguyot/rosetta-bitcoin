# Validation Pipeline

Shared does not define a shared consensus implementation. It defines the
required pipeline and observable failure shape so ports can be compared.

Consensus crypto follows the same rule: Shared defines the backend contract,
strict byte semantics, and shared vector requirements, not one shared native
library. See [`CRYPTO_BACKEND.md`](CRYPTO_BACKEND.md).

## Block Connection Order

```text
decode block
validate header linkage and expected hash
validate proof of work and chain work
validate merkle root
validate transaction structure
validate coinbase rules
load prevouts through block-local UTXO view
verify scripts and signature hashes
build undo entries
apply atomic chainstate mutation
advance validated tip
```

## Performance Lessons From Java

Ports should preserve Java's safe performance shape:

- block-local UTXO view
- batched reads and writes
- reused prepared/backend statements where applicable
- single logical commit per block
- stable timing buckets
- deterministic script failure ordering
- parallel script verification only where transaction ordering and same-block
  dependencies remain correct

## Shared Timing Buckets

```text
utxo_load
script_verify
script_runner_wait
script_sighash_cache_build
script_sighash_legacy
script_sighash_witness
script_sighash_taproot
script_ecdsa_verify
script_schnorr_verify
script_interpreter_eval
utxo_apply
commit
block_connect_store_commit
```

Timing reports should distinguish wall-clock block connection from summed worker
CPU time.
