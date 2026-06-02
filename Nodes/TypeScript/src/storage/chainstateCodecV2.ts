export const CHAINSTATE_CODEC_VERSION = 2;

const PREFIX = {
  utxo: 0x75,
  undo: 0x64,
  tip: 0x74,
  metadata: 0x6d,
  blockIndex: 0x62,
  header: 0x68,
  event: 0x65,
  blocker: 0x78,
} as const;

export interface CodecUtxo {
  height: number;
  valueSats: bigint;
  scriptPubkey: Buffer;
  coinbase: boolean;
}

export interface CodecUndoEntry extends CodecUtxo {
  txidInternal: Buffer;
  vout: number;
}

export interface CodecTip {
  height: number;
  blockHashInternal: Buffer;
}

export interface CodecBlockIndex {
  blockHashInternal: Buffer;
  fileNumber: number;
  fileOffset: number;
  blockSize: number;
}

function ensureU8(value: number, label: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xff) {
    throw new RangeError(`${label} must fit in u8`);
  }
}

function ensureU32(value: number, label: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new RangeError(`${label} must fit in u32`);
  }
}

function ensureU64(value: bigint, label: string): void {
  if (value < 0n || value > 0xffffffffffffffffn) {
    throw new RangeError(`${label} must fit in u64`);
  }
}

function ensureBytes(value: Buffer, length: number, label: string): void {
  if (value.length !== length) {
    throw new RangeError(`${label} must be ${length} bytes`);
  }
}

function chainBytes(chain: string): Buffer {
  const encoded = Buffer.from(chain, "utf8");
  ensureU8(encoded.length, "chain length");
  return Buffer.concat([Buffer.from([encoded.length]), encoded]);
}

function namedKey(prefix: number, name: string): Buffer {
  const encoded = Buffer.from(name, "utf8");
  ensureU8(encoded.length, "name length");
  return Buffer.concat([Buffer.from([prefix, encoded.length]), encoded]);
}

function u32be(value: number): Buffer {
  ensureU32(value, "u32 value");
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value, 0);
  return out;
}

function readU32be(data: Buffer, offset: number): [number, number] {
  if (offset + 4 > data.length) throw new RangeError("truncated u32");
  return [data.readUInt32BE(offset), offset + 4];
}

function u64be(value: bigint): Buffer {
  ensureU64(value, "u64 value");
  const out = Buffer.alloc(8);
  out.writeBigUInt64BE(value, 0);
  return out;
}

function readU64be(data: Buffer, offset: number): [bigint, number] {
  if (offset + 8 > data.length) throw new RangeError("truncated u64");
  return [data.readBigUInt64BE(offset), offset + 8];
}

function varbytes(value: Buffer): Buffer {
  return Buffer.concat([u32be(value.length), value]);
}

function readVarbytes(data: Buffer, offset: number): [Buffer, number] {
  const [length, afterLength] = readU32be(data, offset);
  const end = afterLength + length;
  if (end > data.length) throw new RangeError("truncated varbytes");
  return [data.subarray(afterLength, end), end];
}

function flags(coinbase: boolean): number {
  return coinbase ? 1 : 0;
}

function requireConsumed(offset: number, data: Buffer): void {
  if (offset !== data.length) {
    throw new RangeError(`unexpected trailing bytes: ${data.length - offset}`);
  }
}

export function utxoKey(chain: string, txidInternal: Buffer, vout: number): Buffer {
  ensureBytes(txidInternal, 32, "txid_internal");
  return Buffer.concat([Buffer.from([PREFIX.utxo]), chainBytes(chain), txidInternal, u32be(vout)]);
}

export function utxoPrefixKey(chain: string): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.utxo]), chainBytes(chain)]);
}

export function encodeUtxo(utxo: CodecUtxo): Buffer {
  return Buffer.concat([
    u32be(utxo.height),
    u64be(utxo.valueSats),
    Buffer.from([flags(utxo.coinbase)]),
    varbytes(utxo.scriptPubkey),
  ]);
}

export function decodeUtxo(value: Buffer): CodecUtxo {
  let offset = 0;
  const [height, afterHeight] = readU32be(value, offset);
  offset = afterHeight;
  const [valueSats, afterValue] = readU64be(value, offset);
  offset = afterValue;
  if (offset >= value.length) throw new RangeError("truncated flags");
  const flag = value[offset]!;
  offset += 1;
  const [scriptPubkey, afterScript] = readVarbytes(value, offset);
  offset = afterScript;
  requireConsumed(offset, value);
  return { height, valueSats, scriptPubkey, coinbase: (flag & 1) === 1 };
}

export function undoKey(chain: string, height: number): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.undo]), chainBytes(chain), u32be(height)]);
}

export function encodeUndo(entries: readonly CodecUndoEntry[]): Buffer {
  return Buffer.concat([
    u32be(entries.length),
    ...entries.map((entry) => {
      ensureBytes(entry.txidInternal, 32, "undo txid_internal");
      return Buffer.concat([
        entry.txidInternal,
        u32be(entry.vout),
        u32be(entry.height),
        u64be(entry.valueSats),
        Buffer.from([flags(entry.coinbase)]),
        varbytes(entry.scriptPubkey),
      ]);
    }),
  ]);
}

export function decodeUndo(value: Buffer): CodecUndoEntry[] {
  let offset = 0;
  const [count, afterCount] = readU32be(value, offset);
  offset = afterCount;
  const entries: CodecUndoEntry[] = [];
  for (let index = 0; index < count; index += 1) {
    if (offset + 32 > value.length) throw new RangeError("truncated undo txid");
    const txidInternal = value.subarray(offset, offset + 32);
    offset += 32;
    const [vout, afterVout] = readU32be(value, offset);
    offset = afterVout;
    const [height, afterHeight] = readU32be(value, offset);
    offset = afterHeight;
    const [valueSats, afterValue] = readU64be(value, offset);
    offset = afterValue;
    if (offset >= value.length) throw new RangeError("truncated undo flags");
    const flag = value[offset]!;
    offset += 1;
    const [scriptPubkey, afterScript] = readVarbytes(value, offset);
    offset = afterScript;
    entries.push({ txidInternal, vout, height, valueSats, scriptPubkey, coinbase: (flag & 1) === 1 });
  }
  requireConsumed(offset, value);
  return entries;
}

export function tipKey(chain: string): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.tip]), chainBytes(chain)]);
}

export function encodeTip(tip: CodecTip): Buffer {
  ensureBytes(tip.blockHashInternal, 32, "block_hash_internal");
  return Buffer.concat([u32be(tip.height), tip.blockHashInternal]);
}

export function decodeTip(value: Buffer): CodecTip {
  const [height, offset] = readU32be(value, 0);
  if (offset + 32 !== value.length) throw new RangeError("tip value must contain exactly one hash");
  return { height, blockHashInternal: value.subarray(offset, offset + 32) };
}

export function blockIndexKey(chain: string, height: number): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.blockIndex]), chainBytes(chain), u32be(height)]);
}

export function encodeBlockIndex(index: CodecBlockIndex): Buffer {
  ensureBytes(index.blockHashInternal, 32, "block_hash_internal");
  return Buffer.concat([
    index.blockHashInternal,
    u32be(index.fileNumber),
    u32be(index.fileOffset),
    u32be(index.blockSize),
  ]);
}

export function decodeBlockIndex(value: Buffer): CodecBlockIndex {
  if (value.length !== 44) throw new RangeError("block index value must be 44 bytes");
  return {
    blockHashInternal: value.subarray(0, 32),
    fileNumber: value.readUInt32BE(32),
    fileOffset: value.readUInt32BE(36),
    blockSize: value.readUInt32BE(40),
  };
}

export function headerKey(chain: string, height: number): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.header]), chainBytes(chain), u32be(height)]);
}

export function encodeHeader(serializedHeader: Buffer): Buffer {
  return varbytes(serializedHeader);
}

export function decodeHeader(value: Buffer): Buffer {
  const [header, offset] = readVarbytes(value, 0);
  requireConsumed(offset, value);
  return header;
}

export function metadataKey(name: string): Buffer {
  return namedKey(PREFIX.metadata, name);
}

export function metadataValue(value: string): Buffer {
  return Buffer.from(value, "utf8");
}

export function decodeMetadataValue(value: Buffer): string {
  return value.toString("utf8");
}

export function eventKey(id: string): Buffer {
  return namedKey(PREFIX.event, id);
}

export function blockerKey(chain: string): Buffer {
  return Buffer.concat([Buffer.from([PREFIX.blocker]), chainBytes(chain)]);
}
