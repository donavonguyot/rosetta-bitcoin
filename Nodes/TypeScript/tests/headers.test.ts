import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { TESTNET4_GENESIS } from "../src/chain/genesis.js";
import { TESTNET4 } from "../src/chain/params.js";
import { filterExcludedPeers, PYTHON_NODE_DEFAULT_PEER_ENDPOINT } from "../src/config/peers.js";
import { ProjectTracker } from "../src/db/tracker.js";
import {
  BlockHeaderCodec,
  GetHeadersMessageCodec,
  HeadersMessageCodec,
} from "../src/messages/headers.js";
import {
  ensureGenesis,
  headersSyncDone,
  locatorHeights,
  markHeadersCurrent,
  nextLocator,
  persistHeaders,
} from "../src/sync/headers.js";
import {
  HeaderValidationError,
  headerMeetsTarget,
  validateHeader,
} from "../src/sync/validate.js";

describe("header messages", () => {
  it("round-trips getheaders", () => {
    const locator = [Buffer.alloc(32, 0xaa), BlockHeaderCodec.blockHash(TESTNET4_GENESIS)];
    const message = {
      version: 70_016,
      locatorHashes: locator,
      hashStop: Buffer.alloc(32, 0),
    };
    const decoded = GetHeadersMessageCodec.deserialize(GetHeadersMessageCodec.serialize(message));
    expect(decoded.version).toBe(message.version);
    expect(decoded.locatorHashes.map((hash) => hash.toString("hex"))).toEqual(
      locator.map((hash) => hash.toString("hex")),
    );
    expect(decoded.hashStop).toEqual(message.hashStop);
  });

  it("rejects truncated getheaders payload", () => {
    const bad = Buffer.concat([Buffer.alloc(4), Buffer.from([0x00])]);
    expect(() => GetHeadersMessageCodec.deserialize(bad)).toThrow(/invalid getheaders/);
  });

  it("round-trips headers message with trailing tx count", () => {
    const headers = [TESTNET4_GENESIS];
    const raw = HeadersMessageCodec.serialize({ headers });
    const decoded = HeadersMessageCodec.deserialize(raw);
    expect(decoded.headers).toHaveLength(1);
    expect(BlockHeaderCodec.blockHashHex(decoded.headers[0]!)).toBe(
      BlockHeaderCodec.blockHashHex(TESTNET4_GENESIS),
    );
  });
});

describe("header validation", () => {
  it("matches testnet4 genesis hash", () => {
    expect(BlockHeaderCodec.blockHashHex(TESTNET4_GENESIS)).toBe(TESTNET4.genesisHash);
    expect(BlockHeaderCodec.blockHashHex(TESTNET4_GENESIS)).toBe(
      "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
    );
  });

  it("validates genesis prev and pow", () => {
    expect(headerMeetsTarget(TESTNET4_GENESIS)).toBe(true);
    validateHeader(TESTNET4_GENESIS, Buffer.alloc(32, 0));
  });

  it("rejects bad prev hash", () => {
    const header = {
      version: 1,
      prevBlock: Buffer.alloc(32, 0x01),
      merkleRoot: Buffer.alloc(32, 0x02),
      timestamp: 1_714_777_861,
      bits: 0x1d00ffff,
      nonce: 1,
    };
    expect(() =>
      validateHeader(header, BlockHeaderCodec.blockHash(TESTNET4_GENESIS)),
    ).toThrow(HeaderValidationError);
  });

  it("rejects bad pow", () => {
    const header = {
      version: 1,
      prevBlock: BlockHeaderCodec.blockHash(TESTNET4_GENESIS),
      merkleRoot: Buffer.alloc(32, 0x02),
      timestamp: 1_714_777_861,
      bits: 0x1d00ffff,
      nonce: 1,
    };
    expect(() =>
      validateHeader(header, BlockHeaderCodec.blockHash(TESTNET4_GENESIS)),
    ).toThrow(/proof of work failed/);
  });
});

describe("header sync helpers", () => {
  let tempDir = "";

  it("builds exponential locator heights", () => {
    expect(locatorHeights(10)).toEqual([10, 9, 7, 3, 0]);
  });

  it("seeds genesis and builds locator", () => {
    tempDir = mkdtempSync(join(tmpdir(), "tsbitnode-headers-"));
    const tracker = new ProjectTracker(join(tempDir, "headers.db"));
    ensureGenesis(tracker, TESTNET4);
    const locator = nextLocator(tracker, TESTNET4);
    expect(locator).toHaveLength(1);
    expect(locator[0]!.equals(BlockHeaderCodec.blockHash(TESTNET4_GENESIS))).toBe(true);
    tracker.close();
    rmSync(tempDir, { recursive: true, force: true });
    tempDir = "";
  });

  it("persists linked headers and marks current", () => {
    tempDir = mkdtempSync(join(tmpdir(), "tsbitnode-headers-"));
    const tracker = new ProjectTracker(join(tempDir, "persist.db"));
    ensureGenesis(tracker, TESTNET4);

    const bad = {
      version: 1,
      prevBlock: Buffer.alloc(32, 0xff),
      merkleRoot: Buffer.alloc(32, 0x02),
      timestamp: 1_714_777_861,
      bits: 0x1d00ffff,
      nonce: 999_999_999,
    };
    const [height, , stored] = persistHeaders(tracker, TESTNET4, { headers: [bad] });
    expect(stored).toBe(0);
    expect(height).toBe(0);
    expect(tracker.headerCount()).toBe(1);

    markHeadersCurrent(tracker, TESTNET4);
    expect(tracker.getSyncState("testnet4")?.syncStatus).toBe("headers_current");
    tracker.close();
    rmSync(tempDir, { recursive: true, force: true });
    tempDir = "";
  });

  it("detects header sync completion", () => {
    expect(headersSyncDone(100, 200, 0)).toBe(true);
    expect(headersSyncDone(200, 200, 2000)).toBe(true);
    expect(headersSyncDone(199, 200, 2000)).toBe(false);
  });
});

describe("peer exclusion", () => {
  it("filters PythonNode default peer when alternatives exist", () => {
    const peers = filterExcludedPeers([
      PYTHON_NODE_DEFAULT_PEER_ENDPOINT,
      ["203.0.113.10", 48_333],
    ]);
    expect(peers).toEqual([["203.0.113.10", 48_333]]);
  });
});
