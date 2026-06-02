import type { BlockHeader } from "../types/index.js";
import { transactionWtxid } from "../consensus/witness.js";
import { presaltedShortIdFromUint256Digest, shortIdNonceKey } from "./bip152ShortTxid.js";
import { BlockHeaderCodec } from "./headers.js";
import {
  transactionDeserialize,
  transactionSerialize,
  WITNESS_MARKER,
  type Transaction,
} from "./transaction.js";
import {
  packUint64Le,
  readCompactSize,
  serializeBlockHeader,
  unpackUint64Le,
  writeCompactSize,
} from "../wire/serialize.js";

export interface PrefilledTransaction {
  index: number;
  tx: Transaction;
}

export interface CompactBlockMessage {
  header: BlockHeader;
  shortIdNonce: number;
  shortids: Buffer[];
  prefilled: PrefilledTransaction[];
}

type SidMapInput =
  | Map<Buffer, Transaction>
  | ReadonlyMap<Buffer, Transaction>
  | Map<string, Transaction>
  | ReadonlyMap<string, Transaction>;

function sidHex(sid: Buffer): string {
  return sid.toString("hex");
}

function normalizeSidMap(map: SidMapInput): Map<string, Transaction> {
  const out = new Map<string, Transaction>();
  for (const [key, tx] of map) {
    out.set(typeof key === "string" ? key : sidHex(key), tx);
  }
  return out;
}

export function bitcoinShortTransactionId(
  header: BlockHeader,
  shortIdNonce: number,
  tx: Transaction,
): Buffer {
  const keys = shortIdNonceKey(header, shortIdNonce);
  return presaltedShortIdFromUint256Digest(keys[0], keys[1], transactionWtxid(tx));
}

function compactNonPrefilledShortidSlots(
  compact: CompactBlockMessage,
): Array<[number, Buffer]> {
  const nShort = compact.shortids.length;
  const nPf = compact.prefilled.length;
  const total = nShort + nPf;

  const prefilledByIndex = new Map<number, Transaction>();
  for (const pf of compact.prefilled) {
    prefilledByIndex.set(pf.index, pf.tx);
  }
  if (prefilledByIndex.size !== nPf) {
    throw new Error("duplicate prefilled transaction index in compact block");
  }
  for (const idx of prefilledByIndex.keys()) {
    if (idx < 0) {
      throw new Error("prefilled transaction index negative");
    }
    if (idx >= total) {
      throw new Error("prefilled index out of range for reconstructed block tx count");
    }
  }

  let slotsNeedingSid = 0;
  for (let pos = 0; pos < total; pos += 1) {
    if (!prefilledByIndex.has(pos)) {
      slotsNeedingSid += 1;
    }
  }
  if (slotsNeedingSid !== nShort) {
    throw new Error("prefilled gaps do not align with compact shortid vector length");
  }

  const gaps: Array<[number, Buffer]> = [];
  let shortIndex = 0;
  for (let pos = 0; pos < total; pos += 1) {
    if (prefilledByIndex.has(pos)) {
      continue;
    }
    const sid = compact.shortids[shortIndex];
    if (sid === undefined) {
      throw new Error("not enough shortids for non-prefilled block positions");
    }
    gaps.push([pos, sid]);
    shortIndex += 1;
  }
  if (shortIndex !== nShort) {
    throw new Error("too many shortids for reconstructed block transaction count");
  }
  return gaps;
}

export function reconstructCompactTransactions(
  compact: CompactBlockMessage,
  txsByShortid: SidMapInput,
): Transaction[] {
  const sidMap = normalizeSidMap(txsByShortid);
  const total = compact.shortids.length + compact.prefilled.length;
  const prefilledByIndex = new Map<number, Transaction>();
  for (const pf of compact.prefilled) {
    prefilledByIndex.set(pf.index, pf.tx);
  }
  const gaps = compactNonPrefilledShortidSlots(compact);

  const txsOut: Transaction[] = [];
  let gapIndex = 0;
  for (let pos = 0; pos < total; pos += 1) {
    const prefilled = prefilledByIndex.get(pos);
    if (prefilled !== undefined) {
      txsOut.push(prefilled);
      continue;
    }
    const [, sid] = gaps[gapIndex]!;
    gapIndex += 1;
    const tx = sidMap.get(sidHex(sid));
    if (tx === undefined) {
      throw new Error(`missing compact short ID for block position ${pos}`);
    }
    txsOut.push(tx);
  }
  return txsOut;
}

export function serializeBlockWire(header: BlockHeader, transactions: Transaction[]): Buffer {
  const parts: Buffer[] = [serializeBlockHeader(header), writeCompactSize(transactions.length)];
  const witnessBlock = transactions.some((tx) => tx.witness.length > 0);
  if (witnessBlock) {
    parts.push(WITNESS_MARKER);
  }
  for (const tx of transactions) {
    parts.push(transactionSerialize(tx, { includeWitness: witnessBlock }));
  }
  return Buffer.concat(parts);
}

export function reconstructCompactBlockWire(
  compact: CompactBlockMessage,
  txsByShortid: SidMapInput,
): Buffer {
  return serializeBlockWire(compact.header, reconstructCompactTransactions(compact, txsByShortid));
}

export function tryReconstructCompactBlock(
  compact: CompactBlockMessage,
  pooledTransactions: Iterable<Transaction>,
): Transaction[] | null {
  const bySid = mempoolShortIdTransactionMap(compact, pooledTransactions);
  if (bySid === null) {
    return null;
  }
  const missing = missingIndexesForGetblocktxn(compact, bySid);
  if (missing === null || missing.length > 0) {
    return null;
  }
  try {
    return reconstructCompactTransactions(compact, bySid);
  } catch {
    return null;
  }
}

export function mempoolShortIdTransactionMap(
  compact: CompactBlockMessage,
  pooledTransactions: Iterable<Transaction>,
): Map<string, Transaction> | null {
  const bySid = new Map<string, Transaction>();
  for (const tx of pooledTransactions) {
    const sid = bitcoinShortTransactionId(compact.header, compact.shortIdNonce, tx);
    const key = sidHex(sid);
    const existing = bySid.get(key);
    if (existing === undefined) {
      bySid.set(key, tx);
    } else if (!transactionWtxid(existing).equals(transactionWtxid(tx))) {
      return null;
    }
  }
  return bySid;
}

export function missingIndexesForGetblocktxn(
  compact: CompactBlockMessage,
  txsByShortid: SidMapInput,
): number[] | null {
  try {
    const sidMap = normalizeSidMap(txsByShortid);
    const gaps = compactNonPrefilledShortidSlots(compact);
    return gaps
      .filter(([, sid]) => sidMap.get(sidHex(sid)) === undefined)
      .map(([pos]) => pos)
      .sort((a, b) => a - b);
  } catch {
    return null;
  }
}

export function completeCompactWithBlockTransactions(
  compact: CompactBlockMessage,
  poolMap: SidMapInput,
  indexesRequestedSorted: readonly number[],
  replyTransactions: readonly Transaction[],
): Transaction[] | null {
  try {
    const gaps = compactNonPrefilledShortidSlots(compact);
    const idxToSid = new Map<number, string>(gaps.map(([pos, sid]) => [pos, sidHex(sid)]));
    const indexes = [...indexesRequestedSorted].sort((a, b) => a - b);
    if (indexes.length !== replyTransactions.length) {
      return null;
    }

    const merged = new Map(normalizeSidMap(poolMap));
    for (let i = 0; i < indexes.length; i += 1) {
      const pos = indexes[i]!;
      const replyTx = replyTransactions[i]!;
      const expectedSid = idxToSid.get(pos);
      if (expectedSid === undefined) {
        return null;
      }
      const computed = sidHex(bitcoinShortTransactionId(compact.header, compact.shortIdNonce, replyTx));
      if (computed !== expectedSid) {
        return null;
      }
      merged.set(expectedSid, replyTx);
    }
    return reconstructCompactTransactions(compact, merged);
  } catch {
    return null;
  }
}

export class CompactBlockMessageCodec {
  static readonly COMMAND = "cmpctblock";

  static serialize(message: CompactBlockMessage): Buffer {
    const parts: Buffer[] = [
      serializeBlockHeader(message.header),
      packUint64Le(message.shortIdNonce),
      writeCompactSize(message.shortids.length),
    ];
    for (const sid of message.shortids) {
      if (sid.length !== 6) {
        throw new Error("each shortid must be exactly 6 bytes");
      }
      parts.push(sid);
    }
    parts.push(writeCompactSize(message.prefilled.length));
    let prevIndex = -1;
    for (let i = 0; i < message.prefilled.length; i += 1) {
      const pf = message.prefilled[i]!;
      const diff = i === 0 ? pf.index : pf.index - prevIndex - 1;
      if (diff < 0) {
        throw new Error("prefilled transactions must be ordered by increasing index");
      }
      parts.push(writeCompactSize(diff));
      parts.push(transactionSerialize(pf.tx, { includeWitness: true }));
      prevIndex = pf.index;
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): CompactBlockMessage {
    if (payload.length < 88) {
      throw new Error("cmpctblock too short for header and short_id_nonce");
    }
    const [header, headerEnd] = BlockHeaderCodec.deserialize(payload, 0);
    const [shortIdNonceRaw, nonceEnd] = unpackUint64Le(payload, headerEnd);
    const shortIdNonce = Number(shortIdNonceRaw);
    const [nShort, afterShortCount] = readCompactSize(payload, nonceEnd);
    const needShort = nShort * 6;
    if (afterShortCount + needShort > payload.length) {
      throw new Error("cmpctblock shortid bytes truncated");
    }
    const shortids: Buffer[] = [];
    for (let i = 0; i < nShort; i += 1) {
      shortids.push(payload.subarray(afterShortCount + i * 6, afterShortCount + (i + 1) * 6));
    }
    let offset = afterShortCount + needShort;
    const [nPrefill, afterPrefillCount] = readCompactSize(payload, offset);
    offset = afterPrefillCount;
    const prefilled: PrefilledTransaction[] = [];
    let prevAbs = -1;
    for (let i = 0; i < nPrefill; i += 1) {
      const [delta, afterDelta] = readCompactSize(payload, offset);
      offset = afterDelta;
      const absIndex = prefilled.length === 0 ? delta : prevAbs + 1 + delta;
      if (absIndex <= prevAbs) {
        throw new Error("prefilled transaction indices must be strictly increasing");
      }
      const [tx, afterTx] = transactionDeserialize(payload, offset);
      offset = afterTx;
      prefilled.push({ index: absIndex, tx });
      prevAbs = absIndex;
    }
    if (offset !== payload.length) {
      throw new Error("trailing bytes after cmpctblock");
    }
    return { header, shortIdNonce, shortids, prefilled };
  }
}

export interface GetBlockTxnMessage {
  blockHash: Buffer;
  txnIndexes: number[];
}

export class GetBlockTxnMessageCodec {
  static readonly COMMAND = "getblocktxn";

  static serialize(message: GetBlockTxnMessage): Buffer {
    if (message.blockHash.length !== 32) {
      throw new Error("block hash must be 32 bytes");
    }
    const parts: Buffer[] = [message.blockHash, writeCompactSize(message.txnIndexes.length)];
    for (const index of message.txnIndexes) {
      parts.push(writeCompactSize(index));
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): GetBlockTxnMessage {
    if (payload.length < 32) {
      throw new Error("getblocktxn payload too short for block hash");
    }
    const blockHash = payload.subarray(0, 32);
    const [count, offsetAfterCount] = readCompactSize(payload, 32);
    let offset = offsetAfterCount;
    const txnIndexes: number[] = [];
    for (let i = 0; i < count; i += 1) {
      const [index, next] = readCompactSize(payload, offset);
      txnIndexes.push(index);
      offset = next;
    }
    if (offset !== payload.length) {
      throw new Error("trailing bytes after getblocktxn indexes");
    }
    return { blockHash, txnIndexes };
  }
}

export interface BlockTxnMessage {
  blockHash: Buffer;
  transactions: Transaction[];
}

export class BlockTxnMessageCodec {
  static readonly COMMAND = "blocktxn";

  static serialize(message: BlockTxnMessage): Buffer {
    if (message.blockHash.length !== 32) {
      throw new Error("block hash must be 32 bytes");
    }
    const witnessMode = message.transactions.some((tx) => tx.witness.length > 0);
    const parts: Buffer[] = [message.blockHash, writeCompactSize(message.transactions.length)];
    for (const tx of message.transactions) {
      parts.push(transactionSerialize(tx, { includeWitness: witnessMode }));
    }
    return Buffer.concat(parts);
  }

  static deserialize(payload: Buffer): BlockTxnMessage {
    if (payload.length < 32) {
      throw new Error("blocktxn payload too short for block hash");
    }
    const blockHash = payload.subarray(0, 32);
    const [count, offsetAfterCount] = readCompactSize(payload, 32);
    let offset = offsetAfterCount;
    const transactions: Transaction[] = [];
    for (let i = 0; i < count; i += 1) {
      const [tx, next] = transactionDeserialize(payload, offset);
      transactions.push(tx);
      offset = next;
    }
    if (offset !== payload.length) {
      throw new Error("trailing bytes after blocktxn transactions");
    }
    return { blockHash, transactions };
  }
}

export function compactBlockHash(compact: CompactBlockMessage): Buffer {
  return BlockHeaderCodec.blockHash(compact.header);
}

export function compactBlockHashHex(compact: CompactBlockMessage): string {
  return BlockHeaderCodec.blockHashHex(compact.header);
}
