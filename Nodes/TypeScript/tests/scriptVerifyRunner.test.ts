import { describe, expect, it } from "vitest";

import { hash160 } from "../src/consensus/hash.js";
import { signDer } from "../src/consensus/secp256k1.js";
import { legacySighash } from "../src/consensus/script/sighash.js";
import { ScriptVerifyRunner, ScriptVerifySettings, type ScriptVerifyTask } from "../src/consensus/script/scriptVerifyRunner.js";
import { ScriptVerifyError } from "../src/consensus/script/verify.js";
import type { Transaction } from "../src/messages/transaction.js";
import { p2pkhScriptPubKey, pushData, testPubkeySec1 } from "./helpers/scriptHelpers.js";

function makeTwoInputP2pkhSpend(): {
  transaction: Transaction;
  spentPrevouts: readonly (readonly [number, Buffer])[];
  tasks: ScriptVerifyTask[];
} {
  const privateKeys = [1n, 2n];
  const pubkeys = privateKeys.map((key) => testPubkeySec1(key));
  const scriptPubKeys = pubkeys.map((pubkey) => p2pkhScriptPubKey(hash160(pubkey)));
  const unsigned: Transaction = {
    version: 1,
    inputs: [
      {
        previousOutput: { hash: Buffer.alloc(32, 0x10), index: 0 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_ffff,
      },
      {
        previousOutput: { hash: Buffer.alloc(32, 0x20), index: 1 },
        scriptSig: Buffer.alloc(0),
        sequence: 0xffff_fffe,
      },
    ],
    outputs: [{ value: 70_000, scriptPubKey: Buffer.from([0x51]) }],
    lockTime: 0,
    witness: [],
  };
  const inputs = unsigned.inputs.map((input, inputIndex) => {
    const sighash = legacySighash(unsigned, inputIndex, scriptPubKeys[inputIndex]!, 1);
    const signature = Buffer.concat([signDer(privateKeys[inputIndex]!, sighash), Buffer.from([1])]);
    return {
      ...input,
      scriptSig: Buffer.concat([pushData(signature), pushData(pubkeys[inputIndex]!)]),
    };
  });
  const transaction = { ...unsigned, inputs };
  return {
    transaction,
    spentPrevouts: [
      [50_000, scriptPubKeys[0]!] as const,
      [40_000, scriptPubKeys[1]!] as const,
    ],
    tasks: scriptPubKeys.map((scriptPubKey, inputIndex) => ({
      inputIndex,
      scriptPubKey,
      amount: inputIndex === 0 ? 50_000 : 40_000,
    })),
  };
}

describe("ScriptVerifyRunner", () => {
  it("verifies through the sequential fallback", async () => {
    const { transaction, spentPrevouts, tasks } = makeTwoInputP2pkhSpend();
    const runner = new ScriptVerifyRunner(new ScriptVerifySettings(false, 4, 1));
    try {
      const stats = await runner.verifyInputs(transaction, spentPrevouts, tasks);
      expect(stats.elapsedMs).toBeGreaterThanOrEqual(0);
      expect(stats.mode).toBe("sequential");
    } finally {
      await runner.close();
    }
  });

  it("verifies multi-input transactions through workers", async () => {
    const { transaction, spentPrevouts, tasks } = makeTwoInputP2pkhSpend();
    const runner = new ScriptVerifyRunner(new ScriptVerifySettings(true, 2, 1));
    try {
      const stats = await runner.verifyInputs(transaction, spentPrevouts, tasks);
      expect(stats.elapsedMs).toBeGreaterThanOrEqual(0);
      expect(stats.mode).toBe("native_block_parallel");
    } finally {
      await runner.close();
    }
  });

  it("verifies block-level jobs across transactions through workers", async () => {
    const { transaction, spentPrevouts, tasks } = makeTwoInputP2pkhSpend();
    const runner = new ScriptVerifyRunner(new ScriptVerifySettings(true, 2, 1));
    try {
      const stats = await runner.verifyBlockInputs([
        { transactionIndex: 1, transaction, spentPrevouts, tasks: [tasks[0]!] },
        { transactionIndex: 2, transaction, spentPrevouts, tasks: [tasks[1]!] },
      ]);
      expect(stats.elapsedMs).toBeGreaterThanOrEqual(0);
      expect(stats.mode).toBe("native_block_parallel");
      expect(stats.details.script_worker_wait).toBeGreaterThanOrEqual(0);
    } finally {
      await runner.close();
    }
  });

  it("reports the lowest failing input deterministically", async () => {
    const { transaction, spentPrevouts, tasks } = makeTwoInputP2pkhSpend();
    const badTasks = [...tasks].reverse().map((task) => ({
      ...task,
      scriptPubKey: p2pkhScriptPubKey(Buffer.alloc(20, 0xff)),
    }));
    const runner = new ScriptVerifyRunner(new ScriptVerifySettings(true, 2, 1));
    try {
      await expect(runner.verifyInputs(transaction, spentPrevouts, badTasks)).rejects.toThrow(ScriptVerifyError);
      await expect(runner.verifyInputs(transaction, spentPrevouts, badTasks)).rejects.toThrow(/input 0:/);
    } finally {
      await runner.close();
    }
  });
});
