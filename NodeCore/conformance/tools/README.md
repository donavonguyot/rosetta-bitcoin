# NodeCore Conformance Tools

This directory holds shared tooling that supports conformance evidence across
ports. Tools here are not part of any node runtime.

## Layout

```text
harvest/java/
  Historical Bitcoin Core RPC harvesters for Java regression fixtures.
promote_java_script_fixtures.py
  Bulk importer from Java's cleared fixture tree into NodeCore script corpus.
validate_script_corpus.py
  Structural validator for the NodeCore script corpus manifest and files.
proofs/
  Compact proof capture helpers used by port-level Makefiles and supervisors.
```

The Java harvesters still write fixture bytes into
`Nodes/Java/src/test/resources/fixtures` because those tests currently consume
port-local resources. Keeping the harvesters here prevents Java from owning
cross-port fixture-generation logic while the fixture bytes are migrated into a
broader shared conformance tree over time.

## Java Script Corpus Flow

```bash
python3 NodeCore/conformance/tools/promote_java_script_fixtures.py
python3 NodeCore/conformance/tools/validate_script_corpus.py \
  --summary-path NodeCore/conformance/results/java_script_corpus_validation_2026-06-03.json
```

The promoter preserves Java source filenames and provenance while assigning
stable `scripts.*` fixture IDs. The validator checks required metadata and file
references; warnings identify raw imports that need normalization before they
are considered cross-port ready.
