import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { TESTNET4_GENESIS } from "../src/chain/genesis.js";
import { TESTNET4 } from "../src/chain/params.js";
import { ProjectTracker } from "../src/db/tracker.js";
import { BlockHeaderCodec } from "../src/messages/headers.js";
import {
  buildHeadersResponse,
  HEADER_BATCH_MAX,
} from "../src/p2p/headerServing.js";
import { ensureGenesis } from "../src/sync/headers.js";

function headerAfter(
  prev: typeof TESTNET4_GENESIS,
  merkleByte: number,
  nonceDelta: number,
): ReturnType<typeof BlockHeaderCodec.deserialize>[0] {
  return {
    version: prev.version,
    prevBlock: BlockHeaderCodec.blockHash(prev),
    merkleRoot: Buffer.alloc(32, merkleByte),
    timestamp: prev.timestamp + 600,
    bits: prev.bits,
    nonce: prev.nonce + nonceDelta,
  };
}

describe("buildHeadersResponse", () => {
  it("returns genesis when unknown locator matches only genesis chain", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-hs-gen-"));
    const tracker = new ProjectTracker(join(dir, "gen.db"));
    ensureGenesis(tracker, TESTNET4);
    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [Buffer.alloc(32, 0xbb)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(reply.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(reply.headers[0]!)).toBe(TESTNET4.genesisHash);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns successors after locator fork", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-hs-succ-"));
    const tracker = new ProjectTracker(join(dir, "succ.db"));
    const genesis = ensureGenesis(tracker, TESTNET4);
    const h1 = headerAfter(genesis, 0x12, 1);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: BlockHeaderCodec.blockHashHex(h1),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(h1).toString("hex"),
    });

    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(genesis)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(reply.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(reply.headers[0]!)).toBe(BlockHeaderCodec.blockHashHex(h1));

    const atTip = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(h1)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(atTip.headers).toHaveLength(0);

    const truncated = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(genesis)],
        hashStop: BlockHeaderCodec.blockHash(h1),
      },
      null,
    );
    expect(truncated.headers).toHaveLength(1);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("truncates at HEADER_BATCH_MAX", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-hs-batch-"));
    const tracker = new ProjectTracker(join(dir, "batch.db"));
    const genesis = ensureGenesis(tracker, TESTNET4);
    let prev = genesis;
    let prevHex = TESTNET4.genesisHash;
    for (let height = 1; height <= HEADER_BATCH_MAX + 1; height += 1) {
      const hdr = headerAfter(prev, height % 256, height);
      tracker.recordHeader(TESTNET4.name, {
        height,
        blockHash: BlockHeaderCodec.blockHashHex(hdr),
        prevHash: prevHex,
        headerSerializedHex: BlockHeaderCodec.serialize(hdr).toString("hex"),
      });
      prev = hdr;
      prevHex = BlockHeaderCodec.blockHashHex(hdr);
    }

    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(TESTNET4_GENESIS)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(reply.headers).toHaveLength(HEADER_BATCH_MAX);
    expect(reply.headers[0]!.prevBlock.equals(BlockHeaderCodec.blockHash(genesis))).toBe(true);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns empty for null locator with zero hash stop", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-hs-null-"));
    const tracker = new ProjectTracker(join(dir, "null.db"));
    ensureGenesis(tracker, TESTNET4);
    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      { version: 70_016, locatorHashes: [], hashStop: Buffer.alloc(32, 0) },
      null,
    );
    expect(reply.headers).toHaveLength(0);
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("stops at missing intermediate height", () => {
    const dir = mkdtempSync(join(tmpdir(), "ts-hs-hole-"));
    const tracker = new ProjectTracker(join(dir, "hole.db"));
    const genesis = ensureGenesis(tracker, TESTNET4);
    const h1 = headerAfter(genesis, 0xab, 1);
    const h2 = headerAfter(h1, 0xcd, 1);
    tracker.recordHeader(TESTNET4.name, {
      height: 1,
      blockHash: BlockHeaderCodec.blockHashHex(h1),
      prevHash: TESTNET4.genesisHash,
      headerSerializedHex: BlockHeaderCodec.serialize(h1).toString("hex"),
    });
    tracker.recordHeader(TESTNET4.name, {
      height: 3,
      blockHash: BlockHeaderCodec.blockHashHex(h2),
      prevHash: BlockHeaderCodec.blockHashHex(h1),
      headerSerializedHex: BlockHeaderCodec.serialize(h2).toString("hex"),
    });

    const reply = buildHeadersResponse(
      tracker,
      TESTNET4,
      {
        version: 70_016,
        locatorHashes: [BlockHeaderCodec.blockHash(genesis)],
        hashStop: Buffer.alloc(32, 0),
      },
      null,
    );
    expect(reply.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(reply.headers[0]!)).toBe(BlockHeaderCodec.blockHashHex(h1));
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("header serving constants", () => {
  it("aligns batch limit with Bitcoin getheaders", () => {
    expect(HEADER_BATCH_MAX).toBe(2000);
  });
});
