# Chainstate Codec v2

Codec v2 is the shared byte-level storage model for RocksDB-backed serious
ports. Implementations must pass the golden vectors in
`NodeCore/conformance/fixtures/chainstate_codec_v2_vectors.json`.

## Principles

- Keys and values are binary. Do not store txids, hashes, or scripts as hex
  strings inside RocksDB.
- Heights and vouts use unsigned big-endian integers so range scans sort
  naturally.
- Network/chain names remain UTF-8 because they are small namespace tags.
- All records are versioned by backend metadata: `codec_version = 2`.
- No port may silently upgrade an existing generation in place. Rebuild or
  promote into a new generation ID.

## Prefixes

| Prefix | Hex | Record |
|--------|-----|--------|
| `u` | `75` | UTXO by outpoint |
| `d` | `64` | undo by block height |
| `t` | `74` | validated tip |
| `m` | `6d` | metadata |
| `b` | `62` | block index |
| `h` | `68` | header |
| `e` | `65` | event |
| `x` | `78` | blocker |

## Key Encoding

`chain` is encoded as:

```text
u8 chain_length || chain_utf8
```

UTXO key:

```text
0x75 || chain || txid_internal_32 || u32be(vout)
```

Undo key:

```text
0x64 || chain || u32be(height)
```

Tip key:

```text
0x74 || chain
```

Metadata key:

```text
0x6d || u8 name_length || name_utf8
```

Block index key:

```text
0x62 || chain || u32be(height)
```

Header key:

```text
0x68 || chain || u32be(height)
```

## Value Encoding

UTXO value:

```text
u32be(height)
u64be(value_sats)
u8(flags)       # bit 0 = coinbase
varbytes(script_pubkey_raw)
```

Undo value:

```text
u32be(entry_count)
repeat entry_count:
  txid_internal_32
  u32be(vout)
  u32be(height)
  u64be(value_sats)
  u8(flags)     # bit 0 = coinbase
  varbytes(script_pubkey_raw)
```

Tip value:

```text
u32be(height)
block_hash_internal_32
```

Block index value:

```text
block_hash_internal_32
u32be(file_number)
u32be(file_offset)
u32be(block_size)
```

Header value:

```text
varbytes(serialized_header_80)
```

Metadata values are UTF-8 strings unless a later schema explicitly marks a key
as binary.

`varbytes` is:

```text
u32be(length) || bytes
```

## Required Golden Vectors

Every port must verify:

- UTXO key and value encoding.
- Undo key and value encoding.
- Tip key and value encoding.
- Block index key and value encoding.
- Header key and value encoding.
- Metadata key encoding.

Vectors are intentionally simple and deterministic so failures identify byte
order or string/hex mistakes quickly.
