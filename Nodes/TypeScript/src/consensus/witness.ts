import { createHash } from "node:crypto";

import { WITNESS_COMMITMENT_HEADER, WITNESS_RESERVED_VALUE_SIZE } from "./constants.js";
import { merkleRoot } from "./merkle.js";
import {
  transactionSerialize,
  transactionIsCoinbase,
  type Transaction,
} from "../messages/transaction.js";
import { doubleSha256 } from "../wire/serialize.js";

export function transactionWtxid(transaction: Transaction): Buffer {
  if (transactionIsCoinbase(transaction)) {
    return Buffer.alloc(32, 0);
  }
  return doubleSha256(transactionSerialize(transaction, { includeWitness: true }));
}

export function witnessMerkleRoot(transactions: Transaction[]): Buffer {
  return merkleRoot(transactions.map((tx) => transactionWtxid(tx)));
}

export function extractWitnessCommitment(scriptPubKey: Buffer): Buffer | null {
  if (scriptPubKey.length < 38 || scriptPubKey[0] !== 0x6a || scriptPubKey[1] !== 0x24) {
    return null;
  }
  if (!scriptPubKey.subarray(2, 6).equals(WITNESS_COMMITMENT_HEADER)) {
    return null;
  }
  return scriptPubKey.subarray(6, 38);
}

export function validateWitnessCommitment(coinbase: Transaction, transactions: Transaction[]): void {
  if (!coinbase.witness.length || !coinbase.witness[0]?.length) {
    throw new Error("coinbase witness stack missing reserved value");
  }
  const reserved = coinbase.witness[0]![0]!;
  if (reserved.length !== WITNESS_RESERVED_VALUE_SIZE) {
    throw new Error("coinbase witness reserved value must be 32 bytes");
  }

  let commitmentHash: Buffer | null = null;
  for (const output of coinbase.outputs) {
    const extracted = extractWitnessCommitment(output.scriptPubKey);
    if (extracted !== null) {
      commitmentHash = extracted;
      break;
    }
  }
  if (commitmentHash === null) {
    throw new Error("coinbase missing witness commitment output");
  }

  const root = witnessMerkleRoot(transactions);
  const expected = doubleSha256(Buffer.concat([root, reserved]));
  if (!commitmentHash.equals(expected)) {
    throw new Error(
      `witness commitment mismatch: expected ${expected.toString("hex")}, got ${commitmentHash.toString("hex")}`,
    );
  }
}

export function blockHasWitness(block: { transactions: Transaction[] }): boolean {
  return block.transactions.some((tx) => tx.witness.length > 0);
}
