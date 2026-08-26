# RosettaBitcoin Mojo diagnostic supplement

This directory is the source of the companion artifact for the paper
*RosettaBitcoin: An Artifact-Backed Experience Report on Verification
Infrastructure for Agent-Assisted Consensus Validators*.

The nine files under `evidence/` are byte-preserved copies of diagnostics
created on 2026-06-17. They were not part of the immutable software snapshot
at DOI `10.5281/zenodo.20738249`, are not Project-canonical evidence, and are
not comparable benchmark results. `blocker_56447_provenance.json` is a
post-snapshot provenance recovery derived from the preserved Reference chain.

The package supports only these bounded observations:

- a pure-Mojo cryptographic backend was recorded for a 5k diagnostic, a
  fresh-state validation to height 100,000, and a resume from 100,000 to
  140,234;
- the recorded backend declared no native cryptographic backend or fallback;
- a 45-case shadow comparison and pure/native six-family must-reject checks
  passed; and
- three intentionally defective modes made the reject check fail.

It does not prove the workspace binary gate, production cryptographic safety,
benchmark comparability, implementation independence, causal productivity, or
generalization beyond the exercised chain and test classes.

## Verify

From the repository root:

```bash
python3 Docs/paper/supplement/verify.py
python3 Docs/paper/supplement/build.py
sha256sum Docs/paper/out/rosettabitcoin-mojo-diagnostic-supplement.tar.gz
```

On macOS, replace `sha256sum` with:

```bash
shasum -a 256 Docs/paper/out/rosettabitcoin-mojo-diagnostic-supplement.tar.gz
```

`build.py` fixes member order, timestamps, ownership, and gzip metadata, so
identical source bytes produce an identical archive.

## Deposit metadata

`zenodo_metadata.json` is upload-ready. After deposition, add the returned DOI
to the manuscript and metadata without changing the evidence files.

