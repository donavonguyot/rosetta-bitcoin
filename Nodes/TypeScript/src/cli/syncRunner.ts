#!/usr/bin/env node
import { mkdirSync } from "node:fs";

import { getChain } from "../chain/params.js";
import { resolveManualPeers } from "../config/peers.js";
import { Settings } from "../config/settings.js";
import { ConnectBlockError } from "../consensus/connect.js";
import { ensureNativeSecp256k1Available } from "../consensus/cryptoBackend.js";
import { ScriptVerifyRunner } from "../consensus/script/scriptVerifyRunner.js";
import { NativeNodeState } from "../runtime/nodeState.js";
import { configureLogging } from "../node.js";
import { PeerManager } from "../p2p/manager.js";
import {
  SyncLockHeldError,
  acquireSyncLock,
  parseSyncLockParentPid,
  releaseSyncLock,
  type AcquireSyncLockOptions,
} from "../storage/syncLock.js";
import {
  connectStoredBlocks,
  rebuildValidatedChain,
  repairValidatedIfAhead,
} from "../sync/blocks.js";
import {
  HeaderRefreshAction,
  decideHeaderRefreshAction,
  headerRefreshLogMessage,
} from "../sync/headerRefresh.js";
import {
  ensureGenesis,
  localHeadersCoverBlockFollowup,
  markHeadersCurrent,
  repairSyncState,
  resolveBootstrapStartHeight,
} from "../sync/headers.js";
import { VERSION } from "../index.js";
import { parseCli, parseOptionalInt } from "./args.js";

const options = parseCli(
  process.argv,
  {
    chain: { type: "string" },
    datadir: { type: "string" },
    peers: { type: "string" },
    "log-level": { type: "string" },
    "blocks-target": { type: "string" },
    "blocks-max": { type: "string" },
    "connect-only": { type: "boolean", default: false },
    rebuild: { type: "boolean", default: false },
    "no-header-refresh": { type: "boolean", default: false },
  },
  { name: "tsbitnode-sync", version: VERSION },
);

const blocksTarget = parseOptionalInt(options["blocks-target"]);
const blocksMax = parseOptionalInt(options["blocks-max"]);

const settings = Settings.fromEnv({
  ...(typeof options.chain === "string" ? { chain: options.chain } : {}),
  ...(typeof options.datadir === "string" ? { dataDir: options.datadir } : {}),
  ...(typeof options.peers === "string" ? { peers: options.peers } : {}),
  ...(typeof options["log-level"] === "string" ? { logLevel: options["log-level"] } : {}),
  ...(blocksTarget !== undefined ? { blocksTargetHeight: blocksTarget } : {}),
  ...(blocksMax !== undefined ? { blocksMaxPerRun: blocksMax } : {}),
  ...(options.rebuild ? { rebuildValidatedChain: true } : {}),
  ...(options["no-header-refresh"] ? { noHeaderRefresh: true } : {}),
});

configureLogging(settings.logLevel);
ensureNativeSecp256k1Available();

function syncRunnerLockOptions(): AcquireSyncLockOptions {
  const parentPid = parseSyncLockParentPid(process.env.TSBITNODE_SYNC_LOCK_PARENT_PID);
  if (parentPid !== undefined) {
    return { holder: "syncRunner", parentPid };
  }
  return { holder: "syncRunner" };
}

function updatePhase3(tracker: NativeNodeState, chainName: string): void {
  tracker.updatePhase(
    "phase3",
    "in_progress",
    `Validated through height ${tracker.getValidatedHeight(chainName)} (${tracker.utxoCount(chainName)} UTXOs)`,
  );
}

async function connectStored(settings: Settings, rebuild: boolean): Promise<number> {
  const chain = getChain(settings.chain);
  mkdirSync(settings.dataDir, { recursive: true });
  const tracker = await NativeNodeState.open(settings, chain, { acquireLock: false });
  const scriptVerifyRunner = new ScriptVerifyRunner();
  ensureGenesis(tracker, chain);
  repairSyncState(tracker, chain);
  try {
    await repairValidatedIfAhead(tracker, chain);
    let connected = 0;
    if (rebuild) {
      connected = await rebuildValidatedChain(tracker, chain, { scriptVerifyRunner });
      console.error(
        `Rebuilt validated chain from stored blocks (height=${tracker.getValidatedHeight(chain.name)}, utxos=${await tracker.nativeUtxoCount(chain.name)})`,
      );
    } else {
      const outcome = await connectStoredBlocks(tracker, chain, { scriptVerifyRunner });
      connected = outcome.connected;
    }
    if (connected > 0) {
      updatePhase3(tracker, chain.name);
      console.error(
        `Connected ${connected} stored blocks (validated height=${tracker.getValidatedHeight(chain.name)}, utxos=${await tracker.nativeUtxoCount(chain.name)})`,
      );
    }
    return 0;
  } catch (error) {
    if (error instanceof ConnectBlockError) {
      tracker.logEvent("sync", `Block connect failed: ${error.message}`, "error");
    }
    throw error;
  } finally {
    await scriptVerifyRunner.close();
    await tracker.close();
  }
}

async function syncBlocks(settings: Settings): Promise<number> {
  const chain = getChain(settings.chain);
  mkdirSync(settings.dataDir, { recursive: true });
  const tracker = await NativeNodeState.open(settings, chain, { acquireLock: false });
  const scriptVerifyRunner = new ScriptVerifyRunner();
  ensureGenesis(tracker, chain);
  repairSyncState(tracker, chain);
  const port = settings.p2pPort || chain.defaultPort;
  const manualPeers = resolveManualPeers(settings.peers, port);
  const manager = new PeerManager(chain, tracker, settings);

  try {
    await repairValidatedIfAhead(tracker, chain);
    if (settings.rebuildValidatedChain) {
      const connected = await rebuildValidatedChain(tracker, chain, { scriptVerifyRunner });
      console.error(
        `Rebuilt validated chain before download (height=${tracker.getValidatedHeight(chain.name)}, utxos=${await tracker.nativeUtxoCount(chain.name)})`,
      );
      if (connected > 0) {
        updatePhase3(tracker, chain.name);
      }
    } else {
      const { connected } = await connectStoredBlocks(tracker, chain, { scriptVerifyRunner });
      if (connected > 0) {
        updatePhase3(tracker, chain.name);
        console.error(`Connected ${connected} stored blocks before download`);
      }
    }

    const syncState = tracker.getSyncState(chain.name);
    const syncBest = syncState?.bestHeight ?? 0;
    const handshakeHeight = resolveBootstrapStartHeight(tracker, chain, settings);
    await manager.bootstrap(manualPeers, { startHeight: handshakeHeight });

    const ordered = manager.connections.filter((peer) => peer.isConnected);
    const advertised = ordered[0]?.remoteVersion?.startHeight ?? -1;
    const refreshAction = decideHeaderRefreshAction(settings, tracker, chain, {
      syncBestHeight: syncBest,
      advertisedPeerHeight: advertised,
    });
    const blocksTargetHeight = settings.blocksTargetHeight || 0;
    const localsCoverFollowup = localHeadersCoverBlockFollowup(
      tracker,
      chain,
      blocksTargetHeight,
    );

    if (refreshAction !== HeaderRefreshAction.NetworkSync) {
      markHeadersCurrent(tracker, chain);
      console.error(headerRefreshLogMessage(refreshAction));
    } else {
      await manager.syncHeaders({
        bestEffortIfHeadersCoverFollowupBlocks: localsCoverFollowup,
      });
    }

    const syncAfterHeaders = tracker.getSyncState(chain.name);
    if (syncAfterHeaders?.syncStatus === "headers_current" && settings.listen) {
      await manager.completeDeferredHandshake();
    }

    const downloaded = await manager.syncBlocks({ scriptVerifyRunner });
    const validated = tracker.getValidatedHeight(chain.name);
    if (downloaded > 0 || validated > 0) {
      tracker.updatePhase(
        "phase2",
        "in_progress",
        `${tracker.blockCount(chain.name)} blocks stored, validated through height ${validated}`,
      );
      updatePhase3(tracker, chain.name);
      console.error(
        `Block sync complete: downloaded=${downloaded} stored=${tracker.blockCount(chain.name)} validated=${validated} utxos=${await tracker.nativeUtxoCount(chain.name)}`,
      );
    }
    return 0;
  } catch (error) {
    if (error instanceof ConnectBlockError) {
      tracker.logEvent("sync", `Block connect failed: ${error.message}`, "error");
    }
    throw error;
  } finally {
    await scriptVerifyRunner.close();
    await manager.close();
    await tracker.close();
  }
}

if (options["connect-only"]) {
  let syncLock = null;
  try {
    syncLock = acquireSyncLock(settings.dataDir, syncRunnerLockOptions());
    process.exitCode = await connectStored(settings, Boolean(options.rebuild));
  } catch (error) {
    if (error instanceof SyncLockHeldError) {
      console.error(`error: ${error.message}`);
      process.exitCode = 2;
    } else if (error instanceof Error) {
      console.error(error.message);
      process.exitCode = 1;
    } else {
      process.exitCode = 1;
    }
  } finally {
    if (syncLock !== null) {
      releaseSyncLock(syncLock);
    }
  }
} else {
  let syncLock = null;
  try {
    syncLock = acquireSyncLock(settings.dataDir, syncRunnerLockOptions());
    process.exitCode = await syncBlocks(settings);
  } catch (error) {
    if (error instanceof SyncLockHeldError) {
      console.error(`error: ${error.message}`);
      process.exitCode = 2;
    } else if (error instanceof Error) {
      console.error(error.message);
      process.exitCode = 1;
    } else {
      process.exitCode = 1;
    }
  } finally {
    if (syncLock !== null) {
      releaseSyncLock(syncLock);
    }
  }
}
