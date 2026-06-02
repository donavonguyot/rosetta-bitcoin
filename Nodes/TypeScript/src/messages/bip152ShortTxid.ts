import { createHash } from "node:crypto";

import type { BlockHeader } from "../types/index.js";
import { packUint64Le, serializeBlockHeader } from "../wire/serialize.js";

const U64_MASK = (1n << 64n) - 1n;
const C0 = 0x736f_6d65_7073_6575n;
const C1 = 0x646f_7261_6e64_6f6dn;
const C2 = 0x6c79_6765_6e65_7261n;
const C3 = 0x7465_6462_7974_6573n;

function rotlU64(value: bigint, bits: number): bigint {
  value &= U64_MASK;
  return ((value << BigInt(bits)) | (value >> BigInt(64 - bits))) & U64_MASK;
}

function sipRound(v0: bigint, v1: bigint, v2: bigint, v3: bigint): [bigint, bigint, bigint, bigint] {
  v0 = (v0 + v1) & U64_MASK;
  v1 = rotlU64(v1 ^ v0, 13);
  v0 = rotlU64(v0, 32);
  v2 = (v2 + v3) & U64_MASK;
  v3 = rotlU64(v3 ^ v2, 16);
  v0 = (v0 + v3) & U64_MASK;
  v3 = rotlU64(v3 ^ v0, 21);
  v2 = (v2 + v1) & U64_MASK;
  v1 = rotlU64(v1 ^ v2, 17);
  v2 = rotlU64(v2, 32);
  return [v0, v1, v2, v3];
}

function sipStateFromKeys(k0: bigint, k1: bigint): [bigint, bigint, bigint, bigint] {
  return [
    (C0 ^ k0) & U64_MASK,
    (C1 ^ k1) & U64_MASK,
    (C2 ^ k0) & U64_MASK,
    (C3 ^ k1) & U64_MASK,
  ];
}

export function shortIdNonceKey(header: BlockHeader, shortIdNonce: number | bigint): [bigint, bigint] {
  const digest = createHash("sha256")
    .update(Buffer.concat([serializeBlockHeader(header), packUint64Le(shortIdNonce)]))
    .digest();
  return [digest.readBigUInt64LE(0), digest.readBigUInt64LE(8)];
}

/** Lower 48 bits of Bitcoin Core's PresaltedSipHasher as 6-byte LE. */
export function presaltedShortIdFromUint256Digest(k0: bigint, k1: bigint, digest32: Buffer): Buffer {
  if (digest32.length !== 32) {
    throw new Error("digest must be 32 bytes");
  }
  let [v0, v1, v2, v3] = sipStateFromKeys(k0, k1);
  for (let chunk = 0; chunk < 32; chunk += 8) {
    const d = digest32.readBigUInt64LE(chunk) & U64_MASK;
    v3 = (v3 ^ d) & U64_MASK;
    [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
    [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
    v0 = (v0 ^ d) & U64_MASK;
  }
  const tail = (4n << 59n) & U64_MASK;
  v3 = (v3 ^ tail) & U64_MASK;
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  v0 = (v0 ^ tail) & U64_MASK;
  v2 = (v2 ^ 0xffn) & U64_MASK;
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  [v0, v1, v2, v3] = sipRound(v0, v1, v2, v3);
  let out = (v0 ^ v1 ^ v2 ^ v3) & U64_MASK;
  out &= U64_MASK >> 16n;
  const buf = Buffer.allocUnsafe(6);
  buf.writeUIntLE(Number(out & 0xffff_ffff_ffffn), 0, 6);
  return buf;
}
