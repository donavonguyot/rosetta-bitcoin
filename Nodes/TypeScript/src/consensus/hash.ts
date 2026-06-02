import { createHash } from "node:crypto";

export {
  blockHeaderHashHex,
  doubleSha256,
  messageChecksum,
  packInt32Le,
  packInt64Le,
  packUint32Le,
  packUint64Le,
  readCompactSize,
  serializeBlockHeader,
  unpackInt32Le,
  unpackInt64Le,
  unpackUint32Le,
  unpackUint64Le,
  writeCompactSize,
} from "../wire/serialize.js";

export { blockMerkleRoot, merkleRoot, transactionTxid } from "./merkle.js";

export function sha256Digest(data: Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

export function hash160(data: Buffer): Buffer {
  return createHash("ripemd160").update(sha256Digest(data)).digest();
}
