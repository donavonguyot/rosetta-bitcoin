import { mkdirSync } from "node:fs";
import type { Server } from "node:net";

import { getChain } from "./chain/params.js";
import type { Settings } from "./config/settings.js";
import { ConnectBlockError } from "./consensus/connect.js";
import { ensureNativeSecp256k1Available } from "./consensus/cryptoBackend.js";
import { ScriptVerifyRunner } from "./consensus/script/scriptVerifyRunner.js";
import { NativeNodeState } from "./runtime/nodeState.js";
import { resolveManualPeers } from "./config/peers.js";
import { clearLastError, recordLastError } from "./metrics.js";
import { startMetricsServer, type MetricsServerHandle } from "./metricsHttp.js";
import { PeerManager } from "./p2p/manager.js";
import { broadcastWitnessBlockInv } from "./p2p/peer.js";
import { serveInbound } from "./p2p/server.js";
import {
  SyncLockHeldError,
  acquireSyncLock,
  releaseSyncLock,
  type SyncLockHandle,
} from "./storage/syncLock.js";
import { connectStoredBlocks, rebuildValidatedChain, repairValidatedIfAhead } from "./sync/blocks.js";
import { ensureGenesis, localHeadersCoverBlockFollowup, markHeadersCurrent, repairSyncState, resolveBootstrapStartHeight } from "./sync/headers.js";
import {
  HeaderRefreshAction,
  decideHeaderRefreshAction,
  headerRefreshLogMessage,
} from "./sync/headerRefresh.js";

export interface RunNodeOptions {
  syncOnly?: boolean;
}

function configureLogging(level: string): void {
  const numeric = level.toUpperCase();
  process.env.LOG_LEVEL = numeric;
}

export async function runNode(settings: Settings, options: RunNodeOptions = {}): Promise<number> {
  ensureNativeSecp256k1Available();
  const chain = getChain(settings.chain);
  mkdirSync(settings.dataDir, { recursive: true });

  let syncLock: SyncLockHandle | null = null;
  try {
    syncLock = acquireSyncLock(settings.dataDir, { holder: "tsbitnode" });
  } catch (error) {
    throw error;
  }

  const tracker = await NativeNodeState.open(settings, chain, { acquireLock: false });
  const metricsServer: MetricsServerHandle | null = startMetricsServer(settings, tracker);
  tracker.setMeta("chain", chain.name);
  tracker.setMeta("data_dir", settings.dataDir);
  tracker.upsertSyncState(chain.name, { syncStatus: "starting" });
  tracker.logEvent("node", "Starting tsbitnode", "info", { chain: chain.name });

  ensureGenesis(tracker, chain);
  repairSyncState(tracker, chain);
  await repairValidatedIfAhead(tracker, chain);

  const port = settings.p2pPort || chain.defaultPort;
  const manualPeers = resolveManualPeers(settings.peers, port);
  if (!settings.peers.trim()) {
    tracker.logEvent(
      "p2p",
      "Using DNS seed discovery (TypeScript default; PythonNode ops use 89.167.10.150:48333)",
      "info",
    );
  } else if (
    settings.peers.includes("89.167.10.150") &&
    !manualPeers.some(([host]) => host === "89.167.10.150")
  ) {
    tracker.logEvent(
      "p2p",
      "Excluded PythonNode default peer 89.167.10.150; using alternate endpoint(s)",
      "info",
      { peers: manualPeers.map(([host, peerPort]) => `${host}:${peerPort}`) },
    );
  }
  const handshakeHeight = resolveBootstrapStartHeight(tracker, chain, settings);
  const manager = new PeerManager(chain, tracker, settings);
  const scriptVerifyRunner = new ScriptVerifyRunner();
  let inboundServer: Server | null = null;

  try {
    await manager.bootstrap(manualPeers, { startHeight: handshakeHeight });
    clearLastError(tracker);
    tracker.upsertSyncState(chain.name, { syncStatus: "connected" });
    tracker.updatePhase("phase0", "completed", "Wire protocol and handshake verified");

    const skipHeaderNetwork = settings.noHeaderRefresh || settings.syncSkipHeaders;
    let stored = 0;
    if (skipHeaderNetwork) {
      markHeadersCurrent(tracker, chain);
    } else {
      const ordered = manager.connections.filter((peer) => peer.isConnected);
      const advertised = ordered[0]?.remoteVersion?.startHeight ?? -1;
      const syncState = tracker.getSyncState(chain.name);
      const refreshAction = decideHeaderRefreshAction(settings, tracker, chain, {
        syncBestHeight: syncState?.bestHeight ?? 0,
        advertisedPeerHeight: advertised,
      });
      const localsCoverFollowup = localHeadersCoverBlockFollowup(
        tracker,
        chain,
        settings.blocksTargetHeight || 0,
      );

      if (refreshAction !== HeaderRefreshAction.NetworkSync) {
        markHeadersCurrent(tracker, chain);
        tracker.logEvent("sync", headerRefreshLogMessage(refreshAction), "info");
      } else {
        const headerOptions = {
          bestEffortIfHeadersCoverFollowupBlocks: localsCoverFollowup,
          ...(settings.blocksTargetHeight > 0 ? { stopHeight: settings.blocksTargetHeight } : {}),
        };
        stored = await manager.syncHeaders(headerOptions);
      }
    }

    const refreshed = tracker.getSyncState(chain.name);
    if (refreshed?.syncStatus === "headers_current") {
      tracker.updatePhase(
        "phase1",
        "completed",
        `Header chain synced to height ${refreshed.bestHeight}`,
      );
    } else if (stored > 0) {
      tracker.updatePhase("phase1", "in_progress", "Header chain sync in progress");
    }

    tracker.logEvent(
      "node",
      `Header sync stored ${stored} headers (status=${refreshed?.syncStatus ?? "unknown"}, peers=${manager.connections.length})`,
      "info",
    );

    try {
      await repairValidatedIfAhead(tracker, chain);
      if (settings.rebuildValidatedChain) {
        const rebuilt = await rebuildValidatedChain(tracker, chain, { scriptVerifyRunner });
        if (rebuilt > 0) {
          tracker.updatePhase(
            "phase3",
            "in_progress",
            `Rebuilt validated chain through height ${tracker.getValidatedHeight(chain.name)} (${tracker.utxoCount(chain.name)} UTXOs)`,
          );
        }
      } else {
        const { connected, newHashes } = await connectStoredBlocks(tracker, chain, { scriptVerifyRunner });
        for (const blockHash of newHashes) {
          await broadcastWitnessBlockInv(manager.connections, blockHash, tracker);
        }
        if (connected > 0) {
          tracker.updatePhase(
            "phase3",
            "in_progress",
            `Connected ${connected} blocks to height ${tracker.getValidatedHeight(chain.name)} (${tracker.utxoCount(chain.name)} UTXOs)`,
          );
        }
      }
    } catch (error) {
      if (error instanceof ConnectBlockError) {
        tracker.logEvent("sync", `Block connect failed: ${error.message}`, "error");
        throw error;
      }
      throw error;
    }

    const blocksDownloaded = await manager.syncBlocks({ scriptVerifyRunner });
    const validated = tracker.getValidatedHeight(chain.name);
    if (blocksDownloaded > 0 || validated > 0 || tracker.blockCount(chain.name) > 0) {
      tracker.updatePhase(
        "phase2",
        "in_progress",
        `${tracker.blockCount(chain.name)} blocks stored, validated through height ${validated}`,
      );
      if (validated > 0) {
        tracker.updatePhase(
          "phase3",
          "in_progress",
          `Validated chain through height ${validated} (${tracker.utxoCount(chain.name)} UTXOs)`,
        );
      }
      tracker.logEvent(
        "node",
        `Block sync downloaded=${blocksDownloaded} stored=${tracker.blockCount(chain.name)} validated=${validated} utxos=${tracker.utxoCount(chain.name)}`,
        "info",
      );
    }

    if (options.syncOnly) {
      tracker.upsertSyncState(chain.name, { syncStatus: "running" });
      tracker.logEvent("node", "Sync-only mode complete", "info");
      return 0;
    }

    tracker.upsertSyncState(chain.name, { syncStatus: "running" });
    tracker.logEvent(
      "node",
      `Entering live message loop with ${manager.connections.length} peer(s)`,
      "info",
    );

    if (settings.listen) {
      // Live service mode completes deferred advanced negotiation only after the
      // node has entered the running state; sync-only paths do not advertise
      // relay behavior beyond their validated chainstate.
      await manager.completeDeferredHandshake();
      inboundServer = await serveInbound({
        chain,
        tracker,
        settings,
        mempool: manager.mempool,
        relayTxAccepted: (tx, source) => manager.relayAcceptedTransaction(tx, source),
      });
    }

    await manager.run();
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    tracker.logEvent("node", `Node error: ${message}`, "error");
    recordLastError(tracker, message);
    tracker.upsertSyncState(chain.name, { syncStatus: "error" });
    throw error;
  } finally {
    if (inboundServer) {
      await new Promise<void>((resolve) => inboundServer!.close(() => resolve()));
    }
    await scriptVerifyRunner.close();
    await manager.close();
    await metricsServer?.close();
    await tracker.close();
    if (syncLock !== null) {
      releaseSyncLock(syncLock);
    }
  }
}

export { configureLogging };
