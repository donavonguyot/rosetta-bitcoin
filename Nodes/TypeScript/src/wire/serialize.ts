import { createHash } from "node:crypto";

import type { BlockHeader } from "../types/index.js";

export function doubleSha256(data: Buffer): Buffer {
  const first = createHash("sha256").update(data).digest();
  return createHash("sha256").update(first).digest();
}

export function messageChecksum(payload: Buffer): Buffer {
  return doubleSha256(payload).subarray(0, 4);
}

export function blockHeaderHashHex(header: BlockHeader): string {
  return doubleSha256(serializeBlockHeader(header)).reverse().toString("hex");
}

/** Serialize an 80-byte block header (internal little-endian layout). */
export function serializeBlockHeader(header: BlockHeader): Buffer {
  const buf = Buffer.allocUnsafe(80);
  buf.writeInt32LE(header.version, 0);
  header.prevBlock.copy(buf, 4);
  header.merkleRoot.copy(buf, 36);
  buf.writeUInt32LE(header.timestamp, 68);
  buf.writeUInt32LE(header.bits >>> 0, 72);
  buf.writeUInt32LE(header.nonce >>> 0, 76);
  return buf;
}

export function packUint32Le(value: number): Buffer {
  const buf = Buffer.allocUnsafe(4);
  buf.writeUInt32LE(value >>> 0, 0);
  return buf;
}

export function packInt32Le(value: number): Buffer {
  const buf = Buffer.allocUnsafe(4);
  buf.writeInt32LE(value | 0, 0);
  return buf;
}

export function packInt64Le(value: number | bigint): Buffer {
  const buf = Buffer.allocUnsafe(8);
  buf.writeBigInt64LE(BigInt(value), 0);
  return buf;
}

export function packUint64Le(value: number | bigint): Buffer {
  const buf = Buffer.allocUnsafe(8);
  buf.writeBigUInt64LE(BigInt(value), 0);
  return buf;
}

export function unpackUint32Le(data: Buffer, offset = 0): [number, number] {
  return [data.readUInt32LE(offset), offset + 4];
}

export function unpackInt32Le(data: Buffer, offset = 0): [number, number] {
  return [data.readInt32LE(offset), offset + 4];
}

export function unpackInt64Le(data: Buffer, offset = 0): [bigint, number] {
  return [data.readBigInt64LE(offset), offset + 8];
}

export function unpackUint64Le(data: Buffer, offset = 0): [bigint, number] {
  return [data.readBigUInt64LE(offset), offset + 8];
}

export function readCompactSize(data: Buffer, offset = 0): [number, number] {
  const first = data[offset];
  if (first === undefined) throw new Error("truncated compact size");
  if (first < 0xfd) return [first, offset + 1];
  if (first === 0xfd) {
    const value = data.readUInt16LE(offset + 1);
    return [value, offset + 3];
  }
  if (first === 0xfe) {
    const value = data.readUInt32LE(offset + 1);
    return [value, offset + 5];
  }
  const value = Number(data.readBigUInt64LE(offset + 1));
  return [value, offset + 9];
}

export function writeCompactSize(value: number): Buffer {
  if (value < 0xfd) return Buffer.from([value]);
  if (value <= 0xffff) {
    const buf = Buffer.allocUnsafe(3);
    buf[0] = 0xfd;
    buf.writeUInt16LE(value, 1);
    return buf;
  }
  if (value <= 0xffff_ffff) {
    const buf = Buffer.allocUnsafe(5);
    buf[0] = 0xfe;
    buf.writeUInt32LE(value, 1);
    return buf;
  }
  const buf = Buffer.allocUnsafe(9);
  buf[0] = 0xff;
  buf.writeBigUInt64LE(BigInt(value), 1);
  return buf;
}
