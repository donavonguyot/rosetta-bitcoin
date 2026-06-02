import type { ChainParams } from "../chain/params.js";
import type { Settings } from "../config/settings.js";
import { transactionWtxid } from "../consensus/witness.js";
import type { ProjectTracker } from "../db/tracker.js";
import {
  InvMessageCodec,
  MSG_WITNESS_TX,
  type InventoryVector,
} from "../messages/inventory.js";
import type { Transaction } from "../messages/transaction.js";
import { Mempool, transactionMeetsPeerFeefilter } from "../mempool/mempool.js";
import { META_TXS_RELAYED_TOTAL, incrMetaCounter } from "../metrics.js";
import { syncBlocksToTip } from "../sync/blocks.js";
import { localHeadersCoverBlockFollowup, markHeadersCurrent } from "../sync/headers.js";
import type { PeerEndpoint } from "../types/index.js";
import type { BlockStore } from "../storage/blocks.js";
import { bootstrapPeerTargets, BAN_HANDSHAKE_FAIL } from "./discovery.js";
import { PeerConnection } from "./peer.js";

export type { PeerConnection } from "./peer.js";

export class PeerManager {
  readonly connections: PeerConnection[] = [];
  readonly mempool: Mempool;
  private effectiveMaxOutbound: number;
  private manualSyncPeers = new Set<string>();

  constructor(
    readonly chain: ChainParams,
    readonly tracker: ProjectTracker,
    readonly settings: Settings,
  ) {
    this.effectiveMaxOutbound = settings.maxOutboundPeers;
    this.mempool = new Mempool({ tracker, settings });
  }

  async bootstrap(manualPeers: PeerEndpoint[], options?: { startHeight?: number }): Promise<void> {
    this.manualSyncPeers = new Set(manualPeers.map(([host, port]) => `${host}:${port}`));
    let targets: readonly PeerEndpoint[];
    if (manualPeers.length > 0) {
      this.effectiveMaxOutbound = Math.max(1, this.settings.maxOutboundPeers);
      targets = [...manualPeers];
    } else {
      this.effectiveMaxOutbound = this.settings.maxOutboundPeers;
      targets = await bootstrapPeerTargets(this.chain, this.tracker, this.settings, manualPeers);
    }
    await this.connectPeers(targets, {
      startHeight: options?.startHeight ?? 0,
      discoverPeerAddresses: !this.settings.skipGetaddr,
    });
    if (this.connections.length === 0) {
      throw new Error("Could not connect to any peers");
    }
  }

  async connectPeers(
    targets: readonly PeerEndpoint[],
    options?: { startHeight?: number; discoverPeerAddresses?: boolean },
  ): Promise<void> {
    const startHeight = options?.startHeight ?? 0;
    const discoverPeerAddresses = options?.discoverPeerAddresses ?? true;

    for (const [host, port] of targets) {
      if (this.connections.length >= this.effectiveMaxOutbound) break;
      if (this.connections.some((peer) => peer.host === host && peer.port === port)) continue;

      const connection = new PeerConnection({
        host,
        port,
        chain: this.chain,
        tracker: this.tracker,
        protocolVersion: this.settings.protocolVersion,
        userAgent: this.settings.userAgent,
        startHeight,
        settings: this.settings,
        pingIntervalSeconds: this.settings.pingIntervalSeconds,
        peerStaleSeconds: this.settings.peerStaleSeconds,
      });

      connection.mempool = this.mempool;
      connection.relayTxAccepted = (tx, source) => this.relayAcceptedTransaction(tx, source);

      try {
        await connection.connect();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.tracker.logEvent(
          "p2p",
          `Failed to connect to ${host}:${port}: ${message}`,
          "warning",
          { host, port },
        );
        if (host && host !== "unknown" && port > 0) {
          this.tracker.incrementPeerBanScore(host, port, BAN_HANDSHAKE_FAIL);
        }
        continue;
      }

      this.connections.push(connection);
      if (discoverPeerAddresses) {
        await connection.discoverPeers();
      }
      if (this.connections.length >= this.effectiveMaxOutbound) break;
    }
  }

  private orderedSyncPeers(): PeerConnection[] {
    const manual = this.manualSyncPeers;
    return [...this.connections]
      .filter((peer) => peer.isConnected)
      .sort((left, right) => {
        const leftManual = manual.has(`${left.host}:${left.port}`) ? 0 : 1;
        const rightManual = manual.has(`${right.host}:${right.port}`) ? 0 : 1;
        if (leftManual !== rightManual) return leftManual - rightManual;
        const leftHeight = -(left.remoteVersion?.startHeight ?? 0);
        const rightHeight = -(right.remoteVersion?.startHeight ?? 0);
        return leftHeight - rightHeight;
      });
  }

  async completeDeferredHandshake(): Promise<void> {
    for (const peer of this.connections) {
      if (peer.isConnected) {
        await peer.completeDeferredHandshake();
      }
    }
  }

  async syncHeaders(options?: { bestEffortIfHeadersCoverFollowupBlocks?: boolean }): Promise<number> {
    if (this.settings.syncSkipHeaders || this.settings.noHeaderRefresh) {
      markHeadersCurrent(this.tracker, this.chain);
      return 0;
    }

    const peers = this.orderedSyncPeers();
    if (peers.length === 0) {
      throw new Error("No connected peers available for header sync");
    }

    let lastError: Error | null = null;
    for (const peer of peers) {
      try {
        return await peer.syncHeaders();
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        this.tracker.logEvent(
          "sync",
          `Header sync failed via ${peer.host}:${peer.port}: ${lastError.message}`,
          "warning",
          { host: peer.host, port: peer.port },
        );
      }
    }

    if (
      options?.bestEffortIfHeadersCoverFollowupBlocks &&
      localHeadersCoverBlockFollowup(
        this.tracker,
        this.chain,
        this.settings.blocksTargetHeight || 0,
      )
    ) {
      this.tracker.logEvent(
        "sync",
        `header_sync_best_effort_continuing_block_download error=${lastError?.message ?? "unknown"}`,
        "warning",
      );
      markHeadersCurrent(this.tracker, this.chain);
      return 0;
    }

    throw lastError ?? new Error("Header sync failed on all peers");
  }

  async syncBlocks(blockStore: BlockStore): Promise<number> {
    const peers = this.orderedSyncPeers();
    if (peers.length === 0) {
      throw new Error("No connected peers available for block sync");
    }
    return syncBlocksToTip(peers, this.tracker, this.chain, blockStore, {
      batchSize: this.settings.blocksBatchSize,
      maxBlocks: this.settings.blocksMaxPerRun,
      targetHeight: this.settings.blocksTargetHeight,
      parallelDownloads: this.settings.parallelBlockDownloads,
    });
  }

  /**
   * Announce mempool accept to outbound peers except the broadcaster.
   * cp6 will wire this from inbound `tx` dispatch after admission.
   */
  async relayAcceptedTransaction(tx: Transaction, source: PeerConnection): Promise<void> {
    const inventory: InventoryVector[] = [
      { type: MSG_WITNESS_TX, hash: transactionWtxid(tx) },
    ];
    const payload = InvMessageCodec.serialize({ inventory });
    let relayedAny = false;

    for (const peer of this.connections) {
      if (peer === source || !peer.isConnected) {
        continue;
      }
      if (
        !transactionMeetsPeerFeefilter(tx, this.tracker, peer.peerFeeFilterSatKvb, this.settings.chain)
      ) {
        continue;
      }
      await peer.send(InvMessageCodec.COMMAND, payload);
      relayedAny = true;
    }

    if (relayedAny) {
      incrMetaCounter(this.tracker, META_TXS_RELAYED_TOTAL);
      this.tracker.markWireCapability(
        "tx.inv.send",
        true,
        "live",
        "witness-tx inv after mempool insert",
      );
    }
  }

  async run(): Promise<void> {
    if (this.connections.length === 0) {
      throw new Error("No connected peers for live message loop");
    }
    await Promise.all(this.connections.map((connection) => connection.run()));
  }

  async close(): Promise<void> {
    await Promise.all(this.connections.map((connection) => connection.close()));
    this.connections.length = 0;
  }
}
