import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { TESTNET4 } from "../src/chain/params.js";
import { Settings } from "../src/config/settings.js";
import { ProjectTracker } from "../src/db/tracker.js";
import {
  HeaderRefreshAction,
  decideHeaderRefreshAction,
  headerRefreshLogMessage,
} from "../src/sync/headerRefresh.js";
import { HEADER_SYNC_NEAR_PEER_TIP, ensureGenesis, resolveBootstrapStartHeight } from "../src/sync/headers.js";

function seedHeadersThrough(tracker: ProjectTracker, through: number): void {
  ensureGenesis(tracker, TESTNET4);
  for (let height = 1; height <= through; height += 1) {
    const prev = tracker.getHeaderHash(TESTNET4.name, height - 1) ?? TESTNET4.genesisHash;
    tracker.recordHeader(TESTNET4.name, {
      height,
      blockHash: `${String(height).padStart(64, "0")}`,
      prevHash: prev,
    });
  }
  tracker.upsertSyncState(TESTNET4.name, {
    bestHeight: through,
    bestHash: tracker.getHeaderHash(TESTNET4.name, through) ?? TESTNET4.genesisHash,
    syncStatus: "headers_syncing",
  });
}

describe("header refresh decisions", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    dirs.length = 0;
  });

  function tempTracker(): ProjectTracker {
    const dir = mkdtempSync(join(tmpdir(), "ts-header-refresh-"));
    dirs.push(dir);
    return new ProjectTracker(join(dir, "refresh.db"));
  }

  it("skips when noHeaderRefresh is set", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 3);
    const action = decideHeaderRefreshAction(Settings.fromEnv({ noHeaderRefresh: true }), tracker, TESTNET4, {
      syncBestHeight: 3,
      advertisedPeerHeight: 999_999,
    });
    expect(action).toBe(HeaderRefreshAction.SkipNoHeaderRefresh);
    expect(headerRefreshLogMessage(action)).toBe("header_refresh_skipped_no_header_refresh_flag");
    tracker.close();
  });

  it("skips when syncSkipHeaders is set", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 3);
    const action = decideHeaderRefreshAction(Settings.fromEnv({ syncSkipHeaders: true }), tracker, TESTNET4, {
      syncBestHeight: 3,
      advertisedPeerHeight: 999_999,
    });
    expect(action).toBe(HeaderRefreshAction.SkipSyncSkipHeaders);
    tracker.close();
  });

  it("skips when aligned DB is ahead of peer start_height", () => {
    const tracker = tempTracker();
    const tip = 100;
    seedHeadersThrough(tracker, tip);
    const action = decideHeaderRefreshAction(Settings.fromEnv(), tracker, TESTNET4, {
      syncBestHeight: tip,
      advertisedPeerHeight: tip + 10,
    });
    expect(action).toBe(HeaderRefreshAction.SkipAlignedDbAheadOfPeer);
    expect(headerRefreshLogMessage(action)).toBe("skip_aligned_db_ahead_of_peer");
    tracker.close();
  });

  it("skips when local headers cover blocks target", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 50);
    tracker.setValidatedTip(TESTNET4.name, 10, "0".repeat(64));
    const action = decideHeaderRefreshAction(Settings.fromEnv({ blocksTargetHeight: 40 }), tracker, TESTNET4, {
      syncBestHeight: 50,
      advertisedPeerHeight: 100,
    });
    expect(action).toBe(HeaderRefreshAction.SkipLocalHeadersCoverTarget);
    tracker.close();
  });

  it("network sync when headers do not cover target", () => {
    const tracker = tempTracker();
    ensureGenesis(tracker, TESTNET4);
    tracker.upsertSyncState(TESTNET4.name, {
      bestHeight: 0,
      bestHash: TESTNET4.genesisHash,
    });
    const action = decideHeaderRefreshAction(Settings.fromEnv({ blocksTargetHeight: 5000 }), tracker, TESTNET4, {
      syncBestHeight: 0,
      advertisedPeerHeight: 900_000,
    });
    expect(action).toBe(HeaderRefreshAction.NetworkSync);
    tracker.close();
  });

  it("skips near peer tip", () => {
    const tracker = tempTracker();
    const tip = 10_000;
    seedHeadersThrough(tracker, tip - HEADER_SYNC_NEAR_PEER_TIP);
    const action = decideHeaderRefreshAction(Settings.fromEnv(), tracker, TESTNET4, {
      syncBestHeight: tip - HEADER_SYNC_NEAR_PEER_TIP,
      advertisedPeerHeight: tip,
    });
    expect(action).toBe(HeaderRefreshAction.SkipNearPeerTip);
    tracker.close();
  });

  it("resolveBootstrapStartHeight uses validated tip when skipping header refresh", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 500);
    tracker.setValidatedTip(TESTNET4.name, 42, "0".repeat(64));
    tracker.upsertSyncState(TESTNET4.name, { syncStatus: "headers_current", bestHeight: 500 });
    const height = resolveBootstrapStartHeight(
      tracker,
      TESTNET4,
      Settings.fromEnv({ noHeaderRefresh: true }),
    );
    expect(height).toBe(42);
    tracker.close();
  });

  it("resolveBootstrapStartHeight uses validated tip before headers are current", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 500);
    tracker.setValidatedTip(TESTNET4.name, 42, "0".repeat(64));
    const height = resolveBootstrapStartHeight(
      tracker,
      TESTNET4,
      Settings.fromEnv({ noHeaderRefresh: false, syncSkipHeaders: false }),
    );
    expect(height).toBe(42);
    tracker.close();
  });

  it("resolveBootstrapStartHeight uses header tip once headers_current", () => {
    const tracker = tempTracker();
    seedHeadersThrough(tracker, 500);
    tracker.setValidatedTip(TESTNET4.name, 42, "0".repeat(64));
    tracker.upsertSyncState(TESTNET4.name, { syncStatus: "headers_current", bestHeight: 500 });
    const height = resolveBootstrapStartHeight(
      tracker,
      TESTNET4,
      Settings.fromEnv({ noHeaderRefresh: false, syncSkipHeaders: false }),
    );
    expect(height).toBe(500);
    tracker.close();
  });
});
