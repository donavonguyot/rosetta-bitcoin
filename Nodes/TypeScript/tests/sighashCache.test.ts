import { describe, expect, it } from "vitest";

import {
  bip143Sighash,
  legacySighash,
  taprootSignatureHash,
  TransactionSighashCache,
} from "../src/consensus/script/sighash.js";
import type { Transaction } from "../src/messages/transaction.js";

function fixtureTransaction(): Transaction {
  return {
    version: 2,
    inputs: [
      {
        previousOutput: { hash: Buffer.alloc(32, 0x11), index: 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_fffe,
      },
      {
        previousOutput: { hash: Buffer.alloc(32, 0x22), index: 1 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_fffd,
      },
    ],
    outputs: [
      { value: 40_000, scriptPubKey: Buffer.from([0x51]) },
      { value: 30_000, scriptPubKey: Buffer.from([0x51]) },
    ],
    lockTime: 12,
    witness: [],
  };
}

describe("TransactionSighashCache", () => {
  it("matches uncached legacy and BIP143 sighashes", () => {
    const tx = fixtureTransaction();
    const scriptCode = Buffer.from("76a914" + "01".repeat(20) + "88ac", "hex");
    const cache = new TransactionSighashCache(tx);
    for (const hashType of [1, 2, 3, 0x81, 0x82, 0x83]) {
      expect(cache.legacySighash(0, scriptCode, hashType).equals(legacySighash(tx, 0, scriptCode, hashType))).toBe(true);
      expect(cache.bip143Sighash(1, scriptCode, 50_000, hashType).equals(bip143Sighash(tx, 1, scriptCode, 50_000, hashType))).toBe(true);
    }
  });

  it("matches uncached taproot sighashes", () => {
    const tx = fixtureTransaction();
    const spentPrevouts = [
      [50_000, Buffer.from("5120" + "11".repeat(32), "hex")] as const,
      [60_000, Buffer.from("5120" + "22".repeat(32), "hex")] as const,
    ];
    const cache = new TransactionSighashCache(tx, spentPrevouts);
    for (const hashType of [0, 1, 2, 3, 0x81, 0x82, 0x83]) {
      const options = { hashType, annex: null };
      expect(cache.taprootSignatureHash(1, options).equals(taprootSignatureHash(tx, 1, spentPrevouts, options))).toBe(true);
      const scriptOptions = {
        hashType,
        annex: null,
        extFlag: 1,
        tapleafHash: Buffer.alloc(32, 0x33),
        tapscriptCodeseparatorPos: 7,
      };
      expect(cache.taprootSignatureHash(0, scriptOptions).equals(taprootSignatureHash(tx, 0, spentPrevouts, scriptOptions))).toBe(true);
    }
  });
});
