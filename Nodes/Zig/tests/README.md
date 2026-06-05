# ZigNode Tests

`zig build test` currently exercises the scaffold's reusable core module:

- Chainstate Codec v2 byte key/value golden vectors.
- Port-local operational DB boundary detection.
- Ordered `get_many_utxos` shape.
- Block-local double-spend guard shape.

The Shared script corpus and local-reference P2P gate are CLI-level proofs.
