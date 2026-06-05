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
sqlite-utils query Project/project.db \
  "select port, category, result, result_count from conformance_summary where category like '%crypto%' order by port, result"
```

The durable shared API and vector contract lives in
`Nodes/Shared/consensus/NATIVE_CRYPTO.md`. Backend selection, fallback posture,
and per-port crypto reporting are tracked in
`Nodes/Shared/consensus/CRYPTO_BACKEND.md`.
