# Block flat-file fixtures

Committed `blk*.dat` files for testnet4 integration tests. Avoids relying on gitignored `data/blocks` during CI.

| File | Contents |
|------|----------|
| `blocks/blk00000.dat` | Heights 1–5 testnet4 blocks (258-byte payloads each) |

Record layout matches Bitcoin Core / sibling nodes: `magic (4) + size_le (4) + block_payload`.

Offsets in `blk00000.dat`:

| Height | Offset | Size | Block hash |
|--------|--------|------|------------|
| 1 | 0 | 258 | `0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28` |
| 2 | 266 | 258 | `000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253` |
| 3 | 532 | 258 | `000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56` |
| 4 | 798 | 258 | `000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265` |
| 5 | 1064 | 258 | `00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355` |

Use `tests/blocks_fixture.hpp` (`readFixtureBlock`, `fixtureBlocksDir`) from C++ tests.
