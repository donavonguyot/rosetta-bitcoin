# NodeCore Conformance Tools

This directory holds shared tooling that supports conformance evidence across
ports. Tools here are not part of any node runtime.

## Layout

```text
harvest/java/
  Historical Bitcoin Core RPC harvesters for Java regression fixtures.
proofs/
  Compact proof capture helpers used by port-level Makefiles and supervisors.
```

The Java harvesters still write fixture bytes into
`Nodes/Java/src/test/resources/fixtures` because those tests currently consume
port-local resources. Keeping the harvesters here prevents Java from owning
cross-port fixture-generation logic while the fixture bytes are migrated into a
broader shared conformance tree over time.
