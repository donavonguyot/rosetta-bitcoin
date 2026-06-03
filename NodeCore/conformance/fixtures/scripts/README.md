# Java-Cleared Script Corpus

This corpus bulk-imports Java-cleared testnet4 script fixtures into NodeCore.
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
