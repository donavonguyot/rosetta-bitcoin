import { BlockHeaderCodec } from "../messages/headers.js";
import { transactionDeserialize, type Transaction } from "../messages/transaction.js";
import type { BlockHeader } from "../types/index.js";
import { readCompactSize } from "../wire/serialize.js";

export const BLOCK_WITNESS_MARKER = Buffer.from([0x00, 0x01]);

export interface Block {
  header: BlockHeader;
  transactions: Transaction[];
}

export function blockDeserialize(payload: Buffer): Block {
  const [header, offsetAfterHeader] = BlockHeaderCodec.deserialize(payload, 0);
  let offset = offsetAfterHeader;
  const [txCount, afterTxCount] = readCompactSize(payload, offset);
  offset = afterTxCount;
  if (offset + 1 < payload.length && payload.subarray(offset, offset + 2).equals(BLOCK_WITNESS_MARKER)) {
    offset += 2;
  }
  const transactions: Transaction[] = [];
  for (let index = 0; index < txCount; index += 1) {
    const [transaction, nextOffset] = transactionDeserialize(payload, offset);
    transactions.push(transaction);
    offset = nextOffset;
  }
  if (offset !== payload.length) {
    throw new Error(`trailing block bytes: ${payload.length - offset}`);
  }
  return { header, transactions };
}
