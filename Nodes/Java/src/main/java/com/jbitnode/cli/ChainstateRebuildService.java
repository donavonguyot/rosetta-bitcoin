package com.jbitnode.cli;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.config.NodePaths;
import com.jbitnode.config.PeerConfig;
import com.jbitnode.config.PeerConfig.PeerEndpoint;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.ChainstateStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.BlockSync;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

/** Destructive opt-in chainstate rebuild that downloads block bytes by header hash. */
public final class ChainstateRebuildService {

  private ChainstateRebuildService() {}

  public static int run(PrintStream out) {
    return run(out, System.getenv());
  }

  static int run(PrintStream out, Map<String, String> env) {
    if (!PeerConfig.parseBoolean(env.get("CHAINSTATE_REBUILD"), false)) {
      out.println("chainstate_rebuild error=CHAINSTATE_REBUILD must be set to 1");
      return 2;
    }
    String backend = env.getOrDefault("UTXO_BACKEND", "rocksdb").trim();
    if (!"rocksdb".equalsIgnoreCase(backend)) {
      out.println("chainstate_rebuild error=UTXO_BACKEND must be rocksdb");
      return 2;
    }
    backend = backend.toLowerCase(java.util.Locale.ROOT);

    String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
    ChainParams chain = ChainRegistry.get(chainName);
    List<PeerEndpoint> peers = PeerConfig.parsePeers(env.get("PEERS"), chain.defaultPort());
    int maxBlocks = PeerConfig.parseIntValue(env.get("BLOCKS_MAX"), 5000);
    boolean syncTiming = PeerConfig.parseBoolean(env.get("SYNC_TIMING"), true);
    Path dbPath = NodePaths.dbPathFromEnv(env.get("DATA_DIR"), env.get("DB_PATH"));
    Path dataDir = dbPath.getParent();
    PeerEndpoint peer = peers.getFirst();

    out.println("jbitnode chainstate-rebuild");
    out.println("  chain=" + chain.name());
    out.println("  db=(native-rocksdb)");
    out.println("  peer=" + peer.host() + ":" + peer.port());
    out.println("  blocks_max=" + maxBlocks);
    out.println("  utxo_backend=" + backend);

    try (ChainstateSession session = ChainstateSession.openRebuild(dataDir, dbPath, chain, env)) {
      ProjectTracker tracker = session.tracker();
      ChainstateStore chainstateStore = session.chainstateStore();
      tracker.ensureGenesis(chain.name(), com.jbitnode.chain.Genesis.TESTNET4, chain.genesisHash());
      int headerHeight = tracker.headerCount() - 1;
      if (headerHeight < 1) {
        out.println("  sync_status=error");
        out.println("  error=no headers available for clean rebuild");
        return 3;
      }

      try (PeerConnection connection =
              new PeerConnection(peer.host(), peer.port(), chain, tracker, 0)) {
        connection.connect();
        BlockStorage blockStorage = session.blockStorage();
        BlockSync.Result result =
            BlockSync.syncFromPeer(
                connection,
                chain,
                tracker,
                blockStorage,
                chainstateStore,
                maxBlocks,
                syncTiming ? SyncLocalCoreService.timingEventSink(tracker) : BlockSync.TimingSink.none(),
                true);
        out.println("  downloaded_blocks=" + result.downloaded());
        out.println("  connected_blocks=" + result.connected());
        out.println("  sync_status=" + result.syncStatus());
        SyncLocalCoreService.printTimingSummary(out, result.timingSummary());
        if (result.blockerMessage() != null) {
          out.println("  current_blocker=" + result.blockerMessage());
        }
        tracker.upsertSyncState(
            chain.name(),
            new ProjectTracker.SyncStatePatch(
                null, null, null, "chainstate_rebuild_" + result.syncStatus()));
        int validatedHeight = tracker.getValidatedHeight(chain.name());
        ChainstateStatus chainstateStatus =
            ChainstateStatus.capture(chainstateStore, chain.name());
        out.println("  validated_height=" + validatedHeight);
        out.println("  utxo_count=" + chainstateStatus.backendUtxoCount());
        chainstateStatus.print(out);
        out.println("  binary_gate_status=not_attempted");
        SyncLocalCoreService.printExitSummary(
            out,
            SyncLocalCoreService.exitCodeForSyncStatus(result.syncStatus()),
            result,
            validatedHeight,
            result.syncStatus());
        return SyncLocalCoreService.exitCodeForSyncStatus(result.syncStatus());
      }
    } catch (DatadirLockBusyException error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      return 2;
    } catch (IOException | SQLException | RuntimeException error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      return 1;
    } catch (Exception error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      return 1;
    }
  }

  private static void deleteIfExists(Path path) throws IOException {
    if (!Files.exists(path)) {
      return;
    }
    try (var stream = Files.walk(path)) {
      for (Path child : stream.sorted(Comparator.reverseOrder()).toList()) {
        Files.deleteIfExists(child);
      }
    }
  }
}
