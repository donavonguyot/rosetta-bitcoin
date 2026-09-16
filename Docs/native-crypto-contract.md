# Native Crypto Contract

Ports that support native secp256k1 must report the selected backend explicitly
and prove the shared vectors locally.

## Required Status Fields

```text
native_crypto_backend
native_crypto_available
taproot_tweak_backend
```

## Rules

- The 5k baseline requires native crypto. Managed, pure-language, or fallback
  crypto paths are diagnostic unless the port has already cleared the strict
  baseline with native crypto.
- Do not silently fall back to managed crypto in a native proof. If native crypto
  is requested and unavailable, fail the proof.
- Shared vectors live in `Nodes/Shared/conformance/fixtures/`.
- Each port owns its wrapper and its local tests. Passing Java native crypto does
  not pass C# or any other port.
- Taproot x-only tweak behavior must report whether it is native-backed or
  managed; this field matters for P2TR key-path and script-path confidence.

## Evidence Lookup

Current native-crypto proof artifacts are indexed by Project:

```bash
python3 Project/scripts/report.py --db Project/project.db --section conformance
python3 Project/scripts/query_db.py \
  --sql "select port, category, result, result_count from conformance_summary where category like '%crypto%' order by port, result"
```

The durable shared API and vector contract lives in
`Nodes/Shared/consensus/NATIVE_CRYPTO.md`. Backend selection, fallback posture,
and per-port crypto reporting are tracked in
`Nodes/Shared/consensus/CRYPTO_BACKEND.md`.

## Independent reusable crypto lanes

`own_curve`, `ecosystem_curve`, and `c_binding` are independent dependency
categories, not readiness levels. Existing official baseline/native requirements
remain the C-binding comparison surface. The reusable own-curve 5k experiment
has separate commands, validators and Project results; it never replaces a
canonical baseline artifact or its leaderboard entry.

own_curve permits standard-library hashing, utilities and big integers, but no
existing elliptic-curve implementations, direct/transitive external production
dependencies without documented exceptions, or crypto FFI. ecosystem_curve
permits declared, pinned ecosystem curves, including Zig's standard-library
curve. C wrappers are bindings. The policy applies to standalone package
production dependencies; a node's RocksDB binding remains outside that boundary.

Each package must build independently, expose only public-input verification
operations, preserve explicit encoding/error semantics and integrate through a
thin node adapter. Test-only reference builds are pinned; candidate builds must
exclude alternative crypto backends. Trace/fault-injection builds are distinct
from measured candidate-only builds. Record library source digests, arithmetic
and hashing providers, toolchains, compiler settings and actual selected backend.

Project assembles `rb.crypto_lane_result.v1` artifacts from writer progress,
selecting results by port, lane, implementation and milestone. New evidence is
queried with `python3 Project/scripts/report.py --section crypto-lanes`.
Existing historical Zig artifacts retain their original identities and do not
become new own_curve proofs. New implementations remain experimental. A 5k
proof leaves `binary_gate_status=not_attempted`.
