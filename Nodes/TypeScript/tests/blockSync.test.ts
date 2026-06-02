import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";

const connectBlockMock = vi.hoisted(() => vi.fn());

vi.mock("../src/consensus/connect.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/consensus/connect.js")>();
  return {
    ...actual,
    connectBlock: (...args: Parameters<typeof actual.connectBlock>) => connectBlockMock(...args),
  };
});

import { TESTNET4 } from "../src/chain/params.js";
import { ProjectTracker } from "../src/db/tracker.js";
import { BlockMessageCodec } from "../src/messages/block.js";
import {
  GetDataMessageCodec,
  InventoryVectorCodec,
  InvMessageCodec,
  MSG_WITNESS_BLOCK,
  NotFoundMessageCodec,
  type InventoryVector,
} from "../src/messages/inventory.js";
import type { PeerConnection } from "../src/p2p/peer.js";
import { BlockStore } from "../src/storage/blocks.js";
import {
  requestBlockFromPeersParallel,
  syncBlocksToTip,
} from "../src/sync/blocks.js";
import { ensureGenesis } from "../src/sync/headers.js";

describe("block inventory messages", () => {
  it("round-trips getdata", () => {
    const inv: InventoryVector = { type: MSG_WITNESS_BLOCK, hash: Buffer.alloc(32, 0xab) };
    const payload = GetDataMessageCodec.serialize({ inventory: [inv] });
    const restored = GetDataMessageCodec.deserialize(payload);
    expect(restored.inventory).toHaveLength(1);
    expect(restored.inventory[0]!.type).toBe(MSG_WITNESS_BLOCK);
    expect(restored.inventory[0]!.hash.equals(inv.hash)).toBe(true);
  });

  it("round-trips notfound", () => {
    const inv: InventoryVector = { type: MSG_WITNESS_BLOCK, hash: Buffer.alloc(32, 0xcd) };
    const payload = NotFoundMessageCodec.serialize({ inventory: [inv] });
    const missing = NotFoundMessageCodec.deserialize(payload);
    expect(missing.inventory[0]!.hash.equals(inv.hash)).toBe(true);
  });

  it("round-trips inv via shared codec", () => {
    const item = InventoryVectorCodec.serialize({
      type: MSG_WITNESS_BLOCK,
      hash: Buffer.alloc(32, 0x11),
    });
    const [decoded] = InventoryVectorCodec.deserialize(item);
    expect(decoded.type).toBe(MSG_WITNESS_BLOCK);
    const restored = InvMessageCodec.deserialize(InvMessageCodec.serialize({ inventory: [decoded] }));
    expect(restored.inventory[0]!.hash.equals(decoded.hash)).toBe(true);
  });

  it("passes block payload through block codec", () => {
    const payload = Buffer.alloc(120, 0x42);
    expect(BlockMessageCodec.deserialize(BlockMessageCodec.serialize(payload))).toEqual(payload);
  });
});

describe("block storage", () => {
  it("writes and reads block payloads", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-blk-"));
    try {
      const store = new BlockStore(dir, TESTNET4.magic);
      const blockBytes = Buffer.alloc(120, 0x01);
      const stored = store.write(blockBytes);
      expect(stored.size).toBe(120);
      expect(store.read(stored.fileName, stored.offset, stored.size).equals(blockBytes)).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("missing block heights", () => {
  it("lists headers without stored blocks", () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-missing-"));
    const tracker = new ProjectTracker(join(dir, "blocks.db"));
    try {
      ensureGenesis(tracker, TESTNET4);
      tracker.recordHeader(TESTNET4.name, {
        height: 1,
        blockHash: "hash1",
        prevHash: TESTNET4.genesisHash,
      });
      tracker.recordHeader(TESTNET4.name, {
        height: 2,
        blockHash: "hash2",
        prevHash: "hash1",
      });

      expect(tracker.listMissingBlockHeights(TESTNET4.name, 10)).toEqual([1, 2]);

      tracker.recordBlock(TESTNET4.name, 1, "hash1", "blk00000.dat", 0, 100);
      expect(tracker.listMissingBlockHeights(TESTNET4.name, 10)).toEqual([2]);
    } finally {
      tracker.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("block download helpers", () => {
  beforeEach(() => {
    connectBlockMock.mockReset();
    connectBlockMock.mockImplementation(() => ({
      header: {
        version: 1,
        prevBlock: Buffer.alloc(32),
        merkleRoot: Buffer.alloc(32),
        timestamp: 0,
        bits: 0,
        nonce: 0,
      },
      transactions: [],
    }));
  });

  it("returns the first successful parallel peer response", async () => {
    const target = Buffer.alloc(32, 0x11);
    class FastPeer {
      isConnected = true;
      constructor(
        private readonly delayMs: number,
        private readonly payload: Buffer | null,
      ) {}

      async requestBlock(_blockHash: Buffer): Promise<Buffer | null> {
        await new Promise((resolve) => setTimeout(resolve, this.delayMs));
        return this.payload;
      }
    }

    const fastOk = new FastPeer(0, Buffer.from("winner"));
    const slowOk = new FastPeer(200, Buffer.from("loser"));
    const result = await requestBlockFromPeersParallel(
      [slowOk, fastOk] as unknown as PeerConnection[],
      target,
    );
    expect(result).not.toBeNull();
    expect(result![0].toString()).toBe("winner");
    expect(result![1]).toBe(fastOk);
  });

  it("stops sync at blocks-target using stored height", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tsbitnode-target-"));
    const tracker = new ProjectTracker(join(dir, "target.db"));
    const store = new BlockStore(join(dir, "blocks"), TESTNET4.magic);
    try {
      ensureGenesis(tracker, TESTNET4);
      let prevHex = TESTNET4.genesisHash;
      for (let height = 1; height <= 5; height += 1) {
        const blockHashHex = `${height.toString(16).padStart(64, "0")}`;
        tracker.recordHeader(TESTNET4.name, {
          height,
          blockHash: blockHashHex,
          prevHash: prevHex,
        });
        prevHex = blockHashHex;
      }

      class StubPeer {
        isConnected = true;
        markBlockDownloadCapabilities(): void {}

        async requestBlock(_blockHash: Buffer): Promise<Buffer | null> {
          return Buffer.alloc(120, 0xbb);
        }
      }

      const peer = new StubPeer();
      const total = await syncBlocksToTip([peer] as unknown as PeerConnection[], tracker, TESTNET4, store, {
        batchSize: 16,
        maxBlocks: 0,
        targetHeight: 3,
      });

      expect(total).toBe(3);
      expect(tracker.blockCount(TESTNET4.name)).toBe(3);
      expect(tracker.maxStoredBlockHeight(TESTNET4.name)).toBe(3);
      expect(connectBlockMock).toHaveBeenCalled();
    } finally {
      tracker.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
