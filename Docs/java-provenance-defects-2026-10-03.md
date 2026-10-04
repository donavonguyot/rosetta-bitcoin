# Java correction records — 2026-10-03

Two corrections introduced while establishing the fixture-removal parity
baseline now have explicit cleared identities in Project's `blockers` table.
Their source is the dated addendum to
[`Nodes/Java/docs/BLOCKER_LEDGER.md`](../Nodes/Java/docs/BLOCKER_LEDGER.md), which
the existing importer discovers automatically. Height `-1` denotes a synthetic
vector rather than a chain-height blocker. The entries were written through the
importer; pre-existing blocker rows were preserved.

| Record | Project blocker ID | Correction |
| --- | --- | --- |
| `JAVA-DER-BOUNDS-2026-10-03` | `c1745189110b951b574ab2b3aa07d372681715f34d6303b7a11d1421236b3a1b` | Reject malformed scalar lengths without array overrun |
| `JAVA-TAPROOT-EXPECTATION-2026-10-03` | `817350929c818d165351727c896ab44bf398a7f4d68d229a397a1587c39ab177` | Compare wrong expected Taproot output/parity instead of requiring a throw |

Both were fixed in `6ef3fb3e8a51991567a640d27f66cadb97bf2a57`. The DER fix is in
`Nodes/Java/src/main/java/com/jbitnode/consensus/secp256k1/Secp256k1.java`;
the Taproot correction is in
`Nodes/Java/src/test/java/com/jbitnode/consensus/secp256k1/NativeCryptoVectorContractTest.java`.
The latter is a test-adapter correction, not a change to Taproot calculation.

The existing Shared `native_crypto_v1_vectors.json` already requires rejection
of seven malformed DER classes: truncated sequence, trailing bytes, wrong total
length, missing S, zero R, zero S, and nonminimal R padding. It also carries a
negative-R consensus-invalid vector. In particular,
`ecdsa-malformed-der-missing-s` has a complete R with no S marker/length: before
the bounds fix it could overrun the array. The two Taproot expectation vectors
are `taproot-consensus-invalid-wrong-output` and
`taproot-consensus-invalid-wrong-parity`.

These existing cases are already inside the retained package roots. No new case
or package version was needed; the package remains
`14f375ab39c9c4971336b723712321b2340c1e96400a4a3796dacf0cff52f70b`.
This inspection concerns the Shared crypto-vector corpus; it does not claim that
the separate 45-case positive script corpus or Mojo's six mutation cases are
malformed-DER tests.

The regression test is
`com.jbitnode.consensus.secp256k1.NativeCryptoVectorContractTest#sharedNativeCryptoVectorsRunAgainstAllJavaBackends`.
It executes the vectors on both Java backends and passes with both corrections:

```sh
mvn -B -f Nodes/Java/pom.xml -Dtest=NativeCryptoVectorContractTest test
```

The full 438-case clean parity run is recorded separately in the rollout's
merge-readiness addendum. No additional port correctness fixes accompany these
defect records.
