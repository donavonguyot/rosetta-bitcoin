# Conformance Fixtures

This directory is the neutral index for shared fixture names. Ports may keep
large fixture bytes in their own test resource trees, but must use the fixture
IDs from `../MANIFEST.md` in status exports and conformance results.

## Current Bootstrap Fixtures

```text
blocks.block1_connect
blocks.block2_connect
storage.native_fresh_start
storage.native_restart
storage.local_sqlite_artifact_absent
storage.project_export_observational
sync.deferred_handshake
sync.honest_start_height
sync.single_writer_guard
scripts.p2wpkh_739
scripts.p2tr_key_path_6975
scripts.p2tr_script_path_22830
```

## Script Corpus

The Java-cleared script corpus is stored under:

```text
scripts/
  manifest.json
  MATRIX.md
  scripts.<fixture_id_suffix>/
    block_*.hex
    tx_*.hex
    *_meta.json
    *_prevouts.json
    *_prev_spk.hex
    *_scriptsig.hex
    *_witness*.hex
    ...
```

The copied files intentionally preserve their Java source filenames. Ports
should not depend on Java code or Java test names; they should consume
`manifest.json`, load fixture bytes by `fixture_id`, and report their own
results for that ID.

The initial corpus status is `raw_imported`. A fixture becomes cross-port ready
only after a non-Java loader verifies that the manifest and byte files map cleanly
into that port's script verification API.

## Rule

Fixture names are stable cross-port contracts. Fixture bytes can move; fixture
IDs and expected outcomes should not change without updating the manifest and
the follower matrix together.
