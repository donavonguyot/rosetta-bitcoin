import { BlockHeaderCodec } from "../messages/headers.js";
import { blockDeserialize } from "../consensus/block.js";
import { blockMerkleRoot } from "../consensus/merkle.js";
import { transactionIsCoinbase } from "../messages/transaction.js";
import type { BlockHeader } from "../types/index.js";
import type { Block } from "../consensus/block.js";

export class HeaderValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HeaderValidationError";
  }
}

export class BlockValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BlockValidationError";
  }
}

export function compactToTarget(bits: number): bigint {
  const exponent = bits >>> 24;
  const mantissa = bits & 0x007f_ffff;
  if (mantissa === 0) {
    throw new HeaderValidationError(`Invalid compact bits: 0x${bits.toString(16)}`);
  }
  if (exponent <= 3) {
    return BigInt(mantissa >> (8 * (3 - exponent)));
  }
  return BigInt(mantissa) << BigInt(8 * (exponent - 3));
}

export function headerMeetsTarget(header: BlockHeader): boolean {
  const target = compactToTarget(header.bits);
  if (target === 0n) return false;
  const hashValue = BlockHeaderCodec.blockHash(header);
  let hashInt = 0n;
  for (let index = hashValue.length - 1; index >= 0; index -= 1) {
    hashInt = (hashInt << 8n) | BigInt(hashValue[index]!);
  }
  return hashInt <= target;
}

export function validateHeader(header: BlockHeader, expectedPrev: Buffer): void {
  if (!header.prevBlock.equals(expectedPrev)) {
    throw new HeaderValidationError(
      `prev_block mismatch: expected ${Buffer.from(expectedPrev).reverse().toString("hex")}, ` +
        `got ${Buffer.from(header.prevBlock).reverse().toString("hex")}`,
    );
  }
  if (!headerMeetsTarget(header)) {
    throw new HeaderValidationError(`proof of work failed for bits 0x${header.bits.toString(16)}`);
  }
}

export const MAX_BLOCK_PAYLOAD_BYTES = 4_000_000;
export const MIN_BLOCK_PAYLOAD_BYTES = 80;

export interface ValidateBlockOptions {
  expectedPrev: Buffer;
  expectedHash?: Buffer;
}

export function validateBlock(payload: Buffer, options: ValidateBlockOptions): Block {
  if (payload.length < MIN_BLOCK_PAYLOAD_BYTES) {
    throw new BlockValidationError(`block payload too small: ${payload.length} bytes`);
  }
  if (payload.length > MAX_BLOCK_PAYLOAD_BYTES) {
    throw new BlockValidationError(`block payload too large: ${payload.length} bytes`);
  }

  let block: Block;
  try {
    block = blockDeserialize(payload);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new BlockValidationError(message);
  }

  const header = block.header;
  try {
    validateHeader(header, options.expectedPrev);
  } catch (error) {
    if (error instanceof HeaderValidationError) {
      throw new BlockValidationError(error.message);
    }
    throw error;
  }

  if (options.expectedHash !== undefined) {
    const actualHash = BlockHeaderCodec.blockHash(header);
    if (!actualHash.equals(options.expectedHash)) {
      throw new BlockValidationError(
        `block hash mismatch: expected ${Buffer.from(options.expectedHash).reverse().toString("hex")}, ` +
          `got ${BlockHeaderCodec.blockHashHex(header)}`,
      );
    }
  }

  if (block.transactions.length === 0) {
    throw new BlockValidationError("block has no transactions");
  }

  if (!transactionIsCoinbase(block.transactions[0]!)) {
    throw new BlockValidationError("first transaction must be coinbase");
  }

  const merkleRoot = blockMerkleRoot(block.transactions);
  if (!merkleRoot.equals(header.merkleRoot)) {
    throw new BlockValidationError(
      `merkle root mismatch: expected ${Buffer.from(header.merkleRoot).reverse().toString("hex")}, ` +
        `computed ${Buffer.from(merkleRoot).reverse().toString("hex")}`,
    );
  }

  return block;
}
