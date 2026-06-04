# Java-Cleared Script Corpus

This corpus bulk-imports Java-cleared testnet4 script fixtures into Shared.
The files are evidence and portable test inputs, not Java runtime code.

## Files

```text
manifest.json
  Deterministic index of every imported fixture group.
MATRIX.md
  Cross-port readiness tracker seeded from the manifest.
scripts.<fixture_id_suffix>/
  Raw fixture bytes copied from Java with original filenames preserved.
```

Initial fixtures are marked `raw_imported`. Follower ports should consume
`manifest.json`, load bytes by `fixture_id`, and record their own results before
claiming support for a rule or fixture group.

## Port runners

| Port | Command (native secp required) | Result JSON |
|------|--------------------------------|-------------|
| Python | `cd Nodes/Python && .venv/bin/pybitnode-script-corpus` | `Nodes/Shared/conformance/results/python_script_corpus_<date>.json` |
| C++ | `cd Nodes/Cpp && ./build-core-native/cpbitnode-script-corpus --result-path ../../Nodes/Shared/conformance/results/cpp_script_corpus_<date>.json` | same pattern |

Build C++ with `-DCPBITNODE_USE_NATIVE_SECP256K1=ON`. CTest target: `shared_script_corpus`.

## Debugging a failed fixture

Do **not** implement the fixture’s `missing_rule` string blindly. It records what
blocked the harvesting port at import time, not what your interpreter lacks today.

1. Read [`Docs/script-semantics-gotchas.md`](../../../../Docs/script-semantics-gotchas.md)
   (section **Shared script corpus and MATRIX triage**).
2. Re-run **only** the failing `fixture_id` and capture the full `failure` text in
   the port’s corpus result JSON.
3. Classify: loader/prevouts → template → sighash → stack/terminal → crypto → opcode.
4. Cross-check the same `fixture_id` against the Python corpus runner (must pass
   on the trail oracle before you declare the opcode missing).
5. Update the port column in `MATRIX.md` only after the full manifest passes
   (45/45 for the current corpus).

### Quick symptom map

| Failure message (examples) | Check first |
|--------------------------|-------------|
| `unsupported scriptPubKey template` | Template detection in `verify`, not opcodes |
| `script verification failed` (no detail) | Teach verify to propagate `ScriptError`; then re-run |
| `tapscript failed final stack check` | `CHECKSIGVERIFY` stack residue, `castToBool`, IF/NIP branch |
| `CHECKSIGVERIFY failed` / `EQUALVERIFY failed` | Stack order under witness/tapscript, then sighash |
| `invalid Schnorr signature length` | Stack layout before tapscript `CHECKSIG`, not opcode table |
| `CHECKSEQUENCEVERIFY negative locktime` | CSV disable-flag NOP and wide script-number decode |

## Evidence

Canonical proof JSON belongs in [`Nodes/Shared/conformance/results/`](../../results/).
See [`Nodes/Shared/conformance/ARTIFACT_INVENTORY.md`](../../ARTIFACT_INVENTORY.md).
