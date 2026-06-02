import { transactionSerialize, type Transaction } from "../messages/transaction.js";
import { doubleSha256 } from "../wire/serialize.js";

export function transactionTxid(transaction: Transaction): Buffer {
  return doubleSha256(transactionSerialize(transaction, { includeWitness: false }));
}

export function merkleRoot(hashes: Buffer[]): Buffer {
  if (hashes.length === 0) {
    return Buffer.alloc(32, 0);
  }
  let layer = [...hashes];
  while (layer.length > 1) {
    if (layer.length % 2 === 1) {
      layer.push(layer[layer.length - 1]!);
    }
    const nextLayer: Buffer[] = [];
    for (let index = 0; index < layer.length; index += 2) {
      nextLayer.push(doubleSha256(Buffer.concat([layer[index]!, layer[index + 1]!])));
    }
    layer = nextLayer;
  }
  return layer[0]!;
}

export function blockMerkleRoot(transactions: Transaction[]): Buffer {
  return merkleRoot(transactions.map((tx) => transactionTxid(tx)));
}
