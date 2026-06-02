import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";

import { TESTNET4_GENESIS } from "../src/chain/genesis.js";
import { TESTNET4 } from "../src/chain/params.js";
import { blockDeserialize } from "../src/consensus/block.js";
import { connectBlock, ConnectBlockError, disconnectBlock } from "../src/consensus/connect.js";
import { decodeBip34Height } from "../src/consensus/coinbase.js";
import { blockMerkleRoot, merkleRoot, transactionTxid } from "../src/consensus/merkle.js";
import { blockSubsidy } from "../src/consensus/subsidy.js";
import { validateWitnessCommitment } from "../src/consensus/witness.js";
import { isP2pkh, verifyScript } from "../src/consensus/script/interpreter.js";
import { ProjectTracker } from "../src/db/tracker.js";
import { BlockHeaderCodec } from "../src/messages/headers.js";
import { transactionDeserialize } from "../src/messages/transaction.js";
import { BlockStore } from "../src/storage/blocks.js";
import { connectStoredBlocks, rebuildValidatedChain } from "../src/sync/blocks.js";
import { ensureGenesis } from "../src/sync/headers.js";
import { validateBlock } from "../src/sync/validate.js";

const FIXTURE_BLOCKS_DIR = join(import.meta.dirname, "fixtures", "blocks");

function readFixtureBlock(offset: number, size = 258): Buffer {
  const store = new BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic);
  return store.read("blk00000.dat", offset, size);
}

describe("consensus validation", () => {
  it("computes block subsidy at height one", () => {
    expect(blockSubsidy(1)).toBe(50 * 100_000_000);
  });

  it("matches block1 merkle root", () => {
    const payload = readFixtureBlock(0);
    const block = blockDeserialize(payload);
    expect(blockMerkleRoot(block.transactions).equals(block.header.merkleRoot)).toBe(true);
  });

  it("round-trips coinbase transaction", () => {
    const payload = readFixtureBlock(0);
    const block = blockDeserialize(payload);
    const [restored, offset] = transactionDeserialize(payload, 81);
    expect(offset).toBe(payload.length);
    expect(restored.outputs[0]!.value).toBe(block.transactions[0]!.outputs[0]!.value);
  });

  it("validates block1 structure", () => {
    const payload = readFixtureBlock(0);
    const block = validateBlock(payload, {
      expectedPrev: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
      expectedHash: Buffer.from(
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "hex",
      ).reverse(),
    });
    expect(BlockHeaderCodec.blockHashHex(block.header)).toBe(
      "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
    );
    expect(block.transactions[0]!.outputs[0]!.value).toBe(50 * 100_000_000);
  });

  it("merkle root duplicates last hash", () => {
    const left = Buffer.alloc(32, 0x01);
    const right = Buffer.alloc(32, 0x02);
    expect(merkleRoot([left, right]).equals(merkleRoot([left]))).toBe(false);
    expect(merkleRoot([left]).equals(left)).toBe(true);
  });

  it("decodes BIP34 height from block1 coinbase", () => {
    const block = blockDeserialize(readFixtureBlock(0));
    expect(decodeBip34Height(block.transactions[0]!.inputs[0]!.scriptSig)).toBe(1);
  });

  it("validates witness commitment on block1", () => {
    const block = blockDeserialize(readFixtureBlock(0));
    expect(() => validateWitnessCommitment(block.transactions[0]!, block.transactions)).not.toThrow();
  });

  it("connects block1 and creates coinbase utxo", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "connect.db"));
      ensureGenesis(tracker, TESTNET4);
      tracker.recordHeader(TESTNET4.name, {
        height: 1,
        blockHash: "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        prevHash: TESTNET4.genesisHash,
      });
      const block = connectBlock(tracker, readFixtureBlock(0), {
        height: 1,
        expectedPrev: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
        expectedHash: Buffer.from(
          "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
          "hex",
        ).reverse(),
        chainName: TESTNET4.name,
      });
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(1);
      expect(tracker.utxoCount(TESTNET4.name)).toBe(1);
      const coinbaseTxid = transactionTxid(block.transactions[0]!);
      const utxo = tracker.getUtxo(TESTNET4.name, coinbaseTxid, 0);
      expect(utxo?.value).toBe(50 * 100_000_000);
      expect(utxo?.coinbase).toBe(true);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("requires sequential connect height", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "order.db"));
      ensureGenesis(tracker, TESTNET4);
      tracker.recordHeader(TESTNET4.name, {
        height: 1,
        blockHash: "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        prevHash: TESTNET4.genesisHash,
      });
      expect(() =>
        connectBlock(tracker, readFixtureBlock(0), {
          height: 2,
          expectedPrev: Buffer.alloc(32, 0),
          chainName: TESTNET4.name,
        }),
      ).toThrow(ConnectBlockError);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("disconnect and reconnect block2", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "reorg.db"));
      ensureGenesis(tracker, TESTNET4);
      const hashes = [
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
      ];
      let prev = TESTNET4.genesisHash;
      for (const [index, hashHex] of hashes.entries()) {
        tracker.recordHeader(TESTNET4.name, {
          height: index + 1,
          blockHash: hashHex,
          prevHash: prev,
        });
        prev = hashHex;
      }

      connectBlock(tracker, readFixtureBlock(0), {
        height: 1,
        expectedPrev: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
        expectedHash: Buffer.from(hashes[0]!, "hex").reverse(),
        chainName: TESTNET4.name,
      });
      connectBlock(tracker, readFixtureBlock(266), {
        height: 2,
        expectedPrev: Buffer.from(hashes[0]!, "hex").reverse(),
        expectedHash: Buffer.from(hashes[1]!, "hex").reverse(),
        chainName: TESTNET4.name,
      });
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(2);
      disconnectBlock(tracker, 2, TESTNET4);
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(1);
      connectBlock(tracker, readFixtureBlock(266), {
        height: 2,
        expectedPrev: Buffer.from(hashes[0]!, "hex").reverse(),
        expectedHash: Buffer.from(hashes[1]!, "hex").reverse(),
        chainName: TESTNET4.name,
      });
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(2);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("connects stored blocks 1 through 5", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "chain.db"));
      ensureGenesis(tracker, TESTNET4);
      const localStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
      const offsets = [0, 266, 532, 798, 1064];
      const hashes = [
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
        "000000008ddb4258595f9d8079a0b83fdc2816c9e3511acc739c16f5bce14e56",
        "000000008f5794caa45c418a0184303e848e9d6756e4d77234c9aada983b4265",
        "00000000ccefd2182ad4bb311c866233d32aae0a85f9568588ffd8e0432b7355",
      ];
      let prevHash = TESTNET4.genesisHash;
      for (const [index, offset] of offsets.entries()) {
        const payload = readFixtureBlock(offset);
        const stored = localStore.write(payload);
        tracker.recordHeader(TESTNET4.name, {
          height: index + 1,
          blockHash: hashes[index]!,
          prevHash,
        });
        tracker.recordBlock(
          TESTNET4.name,
          index + 1,
          hashes[index]!,
          stored.fileName,
          stored.offset,
          stored.size,
        );
        prevHash = hashes[index]!;
      }
      const { connected } = await connectStoredBlocks(tracker, localStore, TESTNET4);
      expect(connected).toBe(5);
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(5);
      expect(tracker.utxoCount(TESTNET4.name)).toBe(5);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rebuilds validated chain from stored blocks", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "rebuild.db"));
      ensureGenesis(tracker, TESTNET4);
      const localStore = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
      const payload = readFixtureBlock(0);
      const stored = localStore.write(payload);
      tracker.recordHeader(TESTNET4.name, {
        height: 1,
        blockHash: "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        prevHash: TESTNET4.genesisHash,
      });
      tracker.recordBlock(
        TESTNET4.name,
        1,
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        stored.fileName,
        stored.offset,
        stored.size,
      );
      rebuildValidatedChain(tracker, localStore, TESTNET4);
      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(1);
      expect(tracker.utxoCount(TESTNET4.name)).toBe(1);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("recognizes standard p2pkh script template", () => {
    const script = Buffer.from(
      "76a914" + "00".repeat(20) + "88ac",
      "hex",
    );
    expect(isP2pkh(script)).toBe(true);
    expect(
      verifyScript(Buffer.alloc(0), script, {
        tx: {
          version: 1,
          inputs: [{ previousOutput: { hash: Buffer.alloc(32), index: 0 }, scriptSig: Buffer.alloc(0), sequence: 0xffffffff }],
          outputs: [],
          lockTime: 0,
          witness: [],
        },
        inputIndex: 0,
        amount: 0,
      }),
    ).toBe(false);
  });

  it("preserves sibling vouts when spending one output from the same tx", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "sibling-vout.db"));
      ensureGenesis(tracker, TESTNET4);
      const txid = Buffer.from("11".repeat(32), "hex");
      const scriptPubKey = Buffer.from("0014" + "ab".repeat(20), "hex");
      tracker.addUtxo(TESTNET4.name, txid, 0, {
        height: 5577,
        value: 1_789_197_515,
        scriptPubKey,
        coinbase: false,
      });
      tracker.addUtxo(TESTNET4.name, txid, 5, {
        height: 5577,
        value: 4_501_618_702,
        scriptPubKey,
        coinbase: false,
      });
      tracker.spendUtxo(TESTNET4.name, txid, 5);
      expect(tracker.getUtxo(TESTNET4.name, txid, 0)?.value).toBe(1_789_197_515);
      expect(tracker.getUtxo(TESTNET4.name, txid, 5)).toBeNull();
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rolls back utxo writes when validated tip update fails", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-consensus-"));
    try {
      const tracker = new ProjectTracker(join(dir, "rollback.db"));
      ensureGenesis(tracker, TESTNET4);
      tracker.recordHeader(TESTNET4.name, {
        height: 1,
        blockHash: "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
        prevHash: TESTNET4.genesisHash,
      });

      vi.spyOn(tracker, "setValidatedTip").mockImplementation(() => {
        throw new Error("simulated tip failure");
      });

      expect(() =>
        connectBlock(tracker, readFixtureBlock(0), {
          height: 1,
          expectedPrev: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
          expectedHash: Buffer.from(
            "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
            "hex",
          ).reverse(),
          chainName: TESTNET4.name,
        }),
      ).toThrow("simulated tip failure");

      expect(tracker.getValidatedHeight(TESTNET4.name)).toBe(0);
      expect(tracker.utxoCount(TESTNET4.name)).toBe(0);
      tracker.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
