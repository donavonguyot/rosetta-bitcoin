import type { Transaction } from "../messages/transaction.js";

export class CoinbaseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CoinbaseError";
  }
}

export function decodeBip34Height(scriptSig: Buffer): number | null {
  if (scriptSig.length === 0) return null;
  const opcode = scriptSig[0]!;
  if (opcode === 0) return 0;
  if (opcode >= 0x51 && opcode <= 0x60) return opcode - 0x50;
  if (opcode >= 1 && opcode <= 75) {
    const data = scriptSig.subarray(1, 1 + opcode);
    if (data.length === 0) return null;
    let result = 0;
    for (let index = 0; index < data.length; index += 1) {
      result += data[index]! * 2 ** (8 * index);
    }
    return result;
  }
  return null;
}

export function validateBip34Height(coinbase: Transaction, height: number): void {
  if (height === 0) return;
  const encoded = decodeBip34Height(coinbase.inputs[0]!.scriptSig);
  if (encoded !== height) {
    throw new CoinbaseError(
      `BIP34 height mismatch: expected ${height}, got ${String(encoded)} in coinbase scriptSig`,
    );
  }
}

export function isOpReturn(scriptPubKey: Buffer): boolean {
  return scriptPubKey.length >= 1 && scriptPubKey[0] === 0x6a;
}

export function isSpendableOutput(scriptPubKey: Buffer): boolean {
  return scriptPubKey.length > 0 && !isOpReturn(scriptPubKey);
}
