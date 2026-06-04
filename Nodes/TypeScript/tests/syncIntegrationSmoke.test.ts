import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { NativeNodeState } from "../src/runtime/nodeState.js";
import { runNode } from "../src/node.js";
import { PeerConnection } from "../src/p2p/peer.js";
import { PeerManager } from "../src/p2p/manager.js";
import { ensureGenesis, repairSyncState } from "../src/sync/headers.js";

function seedHeadersAfterGenesis(tracker: NativeNodeState): void {
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
}

function patchPeerManagerNoNetwork(peerHeaderSyncCalls: number[]): void {
  vi.spyOn(PeerManager.prototype, "bootstrap").mockImplementation(async function (
    this: PeerManager,
    manualPeers: Array<[string, number]>,
  ) {
    (this as unknown as { manualSyncPeers: Set<string> }).manualSyncPeers = new Set(
      manualPeers.map(([host, port]) => `${host}:${port}`),
    );
    const fake = {
      isConnected: true,
      remoteVersion: { startHeight: 500_000 },
      host: "127.0.0.1",
      port: 48_333,
      close: vi.fn(async () => undefined),
      completeDeferredHandshake: vi.fn(async () => undefined),
    } as unknown as PeerConnection;
    this.connections.push(fake);
  });

  vi.spyOn(PeerManager.prototype, "syncBlocks").mockImplementation(async () => 0);

  vi.spyOn(PeerConnection.prototype, "syncHeaders").mockImplementation(async () => {
    peerHeaderSyncCalls.push(1);
    return 0;
  });
}

describe("sync integration smoke", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    delete process.env.DATA_DIR;
    delete process.env.DB_PATH;
    delete process.env.PEERS;
    delete process.env.NO_HEADER_REFRESH;
  });

  it("runNode sync-only skips networked header refresh with noHeaderRefresh", async () => {
    const peerHeaderSyncCalls: number[] = [];
    patchPeerManagerNoNetwork(peerHeaderSyncCalls);

    const dir = mkdtempSync(join(tmpdir(), "ts-sync-smoke-"));
    mkdirSync(dir, { recursive: true });
    const settings = new Settings();
    settings.dataDir = dir;
    settings.peers = "127.0.0.1:48333";
    settings.noHeaderRefresh = true;
    settings.skipGetaddr = true;
    settings.logLevel = "critical";

    const code = await runNode(settings, { syncOnly: true });
    expect(code).toBe(0);
    expect(peerHeaderSyncCalls).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  it("PeerManager.syncHeaders marks current without peer calls when noHeaderRefresh", async () => {
    const peerHeaderSyncCalls: number[] = [];
    vi.spyOn(PeerConnection.prototype, "syncHeaders").mockImplementation(async () => {
      peerHeaderSyncCalls.push(1);
      return 0;
    });

    const dir = mkdtempSync(join(tmpdir(), "ts-sync-mgr-"));
    const tracker = new NativeNodeState(join(dir, "mgr.stateDir"));
    ensureGenesis(tracker, TESTNET4);
    seedHeadersAfterGenesis(tracker);

    const settings = new Settings();
    settings.noHeaderRefresh = true;
    const manager = new PeerManager(TESTNET4, tracker, settings);
    const fake = {
      isConnected: true,
      remoteVersion: { startHeight: 100 },
      host: "127.0.0.1",
      port: 48_333,
      close: vi.fn(async () => undefined),
    } as unknown as PeerConnection;
    manager.connections.push(fake);

    const stored = await manager.syncHeaders();
    expect(stored).toBe(0);
    expect(peerHeaderSyncCalls).toEqual([]);
    expect(tracker.getSyncState(TESTNET4.name)?.syncStatus).toBe("headers_current");

    await manager.close();
    tracker.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("runNode sync-only completes block sync path with mocked peers", async () => {
    const syncBlockCalls: number[] = [];
    patchPeerManagerNoNetwork([]);
    vi.spyOn(PeerManager.prototype, "syncBlocks").mockImplementation(async function (this: PeerManager) {
      syncBlockCalls.push(1);
      return 0;
    });

    const dir = mkdtempSync(join(tmpdir(), "ts-sync-blocks-"));
    mkdirSync(dir, { recursive: true });
    const settings = new Settings();
    settings.dataDir = dir;
    settings.peers = "127.0.0.1:48333";
    settings.noHeaderRefresh = true;
    settings.skipGetaddr = true;
    settings.logLevel = "critical";

    const code = await runNode(settings, { syncOnly: true });
    expect(code).toBe(0);
    expect(syncBlockCalls).toHaveLength(1);
    rmSync(dir, { recursive: true, force: true });
  });
});
