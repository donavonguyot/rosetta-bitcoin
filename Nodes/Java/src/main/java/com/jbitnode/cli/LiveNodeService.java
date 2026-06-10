package com.jbitnode.cli;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.config.NodePaths;
import com.jbitnode.config.PeerConfig;
import com.jbitnode.config.PeerConfig.PeerEndpoint;
import com.jbitnode.db.ChainstateInvariantException;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.BlockSync;
import com.jbitnode.sync.ChainInconsistentException;
import com.jbitnode.sync.HeaderSync;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;

/** Long-running live tip maintenance loop built on the proven one-shot sync path. */
public final class LiveNodeService {

  static final int EXIT_BLOCKED = SyncLocalCoreService.EXIT_BLOCKED;

  private LiveNodeService() {}

  @FunctionalInterface
  interface Sleeper {
    void sleep(long millis) throws InterruptedException;
  }

  static int run(PrintStream out, Map<String, String> env) {
    return run(out, env, Thread::sleep);
  }

  static int run(PrintStream out, Map<String, String> env, Sleeper sleeper) {
    try {
      com.jbitnode.consensus.secp256k1.Secp256k1.ensureNativeRuntimeBackend(env);
    } catch (com.jbitnode.consensus.secp256k1.Secp256k1.Secp256k1Error error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      out.println("live_exit_summary exit_code=2 reason=secp256k1_backend iterations=0");
      return 2;
    }
    String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
    ChainParams chain = ChainRegistry.get(chainName);
    List<PeerEndpoint> peers = PeerConfig.parsePeers(env.get("PEERS"), chain.defaultPort());
    int maxHeaders = PeerConfig.parseIntValue(env.get("HEADERS_MAX"), HeaderSync.DEFAULT_MAX_HEADERS);
    int maxBatches =
        PeerConfig.parseIntValue(env.get("HEADER_BATCHES_MAX"), HeaderSync.DEFAULT_HEADER_BATCHES_MAX);
    int maxBlocks = PeerConfig.parseIntValue(env.get("BLOCKS_MAX"), 64);
    int maxIterations = PeerConfig.parseIntValue(env.get("LIVE_MAX_ITERATIONS"), 0);
    long pollMillis = Math.max(0, PeerConfig.parseIntValue(env.get("LIVE_POLL_MS"), 30_000));
    long reconnectMillis = Math.max(0, PeerConfig.parseIntValue(env.get("LIVE_RECONNECT_MS"), 5_000));
    boolean syncTiming = PeerConfig.parseBoolean(env.get("SYNC_TIMING"), false);
    boolean requireBackendAligned = PeerConfig.parseBoolean(env.get("REQUIRE_ROCKSDB_ALIGNED"), true);

    Path dbPath = NodePaths.dbPathFromEnv(env.get("DATA_DIR"), env.get("DB_PATH"));
    Path dataDir = dbPath.getParent();
    Path stopFile = dataDir.resolve(".stop_live");
    PeerEndpoint peer = peers.getFirst();

    out.println("jbitnode live-node");
    out.println("  chain=" + chain.name());
    out.println("  db=(native-rocksdb)");
    out.println("  peer=" + peer.host() + ":" + peer.port());
    out.println("  headers_max=" + maxHeaders + " batches_max=" + maxBatches);
    out.println("  blocks_max=" + maxBlocks + " max_iterations=" + maxIterations);

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(dataDir, dbPath, chain, env, requireBackendAligned)) {
      ProjectTracker tracker = session.tracker();
      BlockStorage blockStorage = session.blockStorage();
      out.println("  utxo_backend=" + session.chainstateStore().backend());
        tracker.logEvent(
            "live",
            "live_start",
            "info",
            details(
                "peer",
                peer.host() + ":" + peer.port(),
                "validated_height",
                tracker.getValidatedHeight(chain.name())));
        int iterations = 0;
        int reconnects = 0;
        int stalls = 0;
        while (true) {
          if (Files.exists(stopFile)) {
            tracker.logEvent("live", "live_stop", "info", "{\"reason\":\"stop_file\"}");
            out.println("live_exit_summary exit_code=0 reason=stop_file iterations=" + iterations);
            return 0;
          }
          if (maxIterations > 0 && iterations >= maxIterations) {
            tracker.logEvent("live", "live_stop", "info", "{\"reason\":\"max_iterations\"}");
            out.println("live_exit_summary exit_code=0 reason=max_iterations iterations=" + iterations);
            return 0;
          }
          iterations += 1;
          try {
            IterationResult result =
                runIteration(
                    chain,
                    tracker,
                    blockStorage,
                    session,
                    peer,
                    maxHeaders,
                    maxBatches,
                    maxBlocks,
                    syncTiming,
                    out);
            if ("blocks_blocked".equals(result.syncStatus())) {
              if (isTransientBlocker(result)) {
                stalls += 1;
                reconnects += 1;
                tracker.logEvent(
                    "live",
                    "peer_reconnect",
                    "warning",
                    details("peer", peer.host() + ":" + peer.port(), "error", result.blockerMessage()));
                logIteration(tracker, chain.name(), iterations, result);
                printProgressJson(out, chain.name(), peer, iterations, reconnects, stalls, result);
                if (maxIterations > 0 && iterations >= maxIterations) {
                  tracker.logEvent("live", "live_stop", "info", "{\"reason\":\"max_iterations\"}");
                  out.println(
                      "live_exit_summary exit_code=0 reason=max_iterations iterations=" + iterations);
                  return 0;
                }
                sleep(sleeper, reconnectMillis);
                continue;
              }
              stalls += 1;
              logIteration(tracker, chain.name(), iterations, result);
              printProgressJson(out, chain.name(), peer, iterations, reconnects, stalls, result);
              out.println(
                  "live_exit_summary exit_code="
                      + EXIT_BLOCKED
                      + " reason=blocks_blocked iterations="
                      + iterations);
              return EXIT_BLOCKED;
            }
            logIteration(tracker, chain.name(), iterations, result);
            printProgressJson(out, chain.name(), peer, iterations, reconnects, stalls, result);
            sleep(sleeper, pollMillis);
          } catch (IOException error) {
            reconnects += 1;
            tracker.logEvent(
                "live",
                "peer_reconnect",
                "warning",
                details(
                    "peer",
                    peer.host() + ":" + peer.port(),
                    "error",
                    error.getMessage().replace("\"", "'"),
                    "reconnects",
                    reconnects));
            out.println("  peer_error=" + error.getMessage());
            if (maxIterations > 0 && iterations >= maxIterations) {
              out.println("live_exit_summary exit_code=1 reason=peer_error iterations=" + iterations);
              return 1;
            }
            sleep(sleeper, reconnectMillis);
          }
        }
    } catch (DatadirLockBusyException error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      out.println("live_exit_summary exit_code=2 reason=lock_busy iterations=0");
      return 2;
    } catch (ChainInconsistentException | ChainstateInvariantException | SQLException | IOException error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      if (error instanceof ChainstateInvariantException) {
        logLiveStopAfterOpenFailure(dataDir, error.getMessage());
        String reason =
            error.getMessage() != null && error.getMessage().contains("not aligned")
                ? "rocksdb_misaligned"
                : "chainstate_invariant";
        out.println("live_exit_summary exit_code=3 reason=" + reason + " iterations=0");
        return 3;
      }
      out.println("live_exit_summary exit_code=1 reason=error iterations=0");
      return 1;
    }
  }

  private static IterationResult runIteration(
      ChainParams chain,
      ProjectTracker tracker,
      BlockStorage blockStorage,
      ChainstateSession session,
      PeerEndpoint peer,
      int maxHeaders,
      int maxBatches,
      int maxBlocks,
      boolean syncTiming,
      PrintStream out)
      throws IOException, SQLException {
    int startHeight = tracker.bootstrapStartHeight(chain.name());
    // Honest start_height: bootstrap from validated runtime truth so the peer handshake does not
    // advertise headers that this datadir has not connected.
    int before = tracker.getValidatedHeight(chain.name());
    try (PeerConnection connection =
        new PeerConnection(peer.host(), peer.port(), chain, tracker, startHeight)) {
      connection.connect();
      HeaderSync.Result headerResult =
          HeaderSync.syncFromPeer(connection, chain, tracker, maxHeaders, maxBatches);
      BlockSync.Result blockResult =
          BlockSync.syncFromPeer(
              connection,
              chain,
              tracker,
              blockStorage,
              session.chainstateStore(),
              maxBlocks,
              BlockSync.TimingSink.none(),
              false);
      if (syncTiming) {
        SyncLocalCoreService.printTimingSummary(out, blockResult.timingSummary());
      }
      int after = tracker.getValidatedHeight(chain.name());
      ChainstateStatus chainstateStatus =
          ChainstateStatus.capture(session.chainstateStore(), chain.name());
      ProjectTracker.SyncState syncState = tracker.getSyncState(chain.name()).orElse(null);
      int headerHeight = syncState != null ? syncState.bestHeight() : 0;
      int storedBlockHeight = tracker.maxStoredBlockHeight(chain.name());
      String validatedHash = tracker.getValidatedHash(chain.name());
      chainstateStatus.print(out);
      out.println(
          "live_iteration_summary header_status="
              + headerResult.syncStatus()
              + " block_status="
              + blockResult.syncStatus()
              + " validated_height="
              + after
              + " delta="
              + (after - before));
      return new IterationResult(
          headerResult.syncStatus(),
          blockResult.syncStatus(),
          before,
          after,
          validatedHash,
          headerHeight,
          storedBlockHeight,
          chainstateStatus.backendUtxoCount(),
          blockResult.downloaded(),
          blockResult.connected(),
          blockResult.blockerMessage());
    }
  }

  private static void logIteration(
      ProjectTracker tracker, String chain, int iteration, IterationResult result) throws SQLException {
    tracker.logEvent(
        "live",
        "live_iteration",
        "info",
        details(
            "iteration",
            iteration,
            "validated_height",
            result.validatedAfter(),
            "delta",
            result.validatedAfter() - result.validatedBefore(),
            "sync_status",
            result.syncStatus()));
    if (result.validatedAfter() > result.validatedBefore()) {
      tracker.logEvent(
          "live",
          "tip_advanced",
          "info",
          details("chain", chain, "validated_height", result.validatedAfter()));
    } else if ("blocks_current".equals(result.syncStatus())) {
      tracker.logEvent(
          "live",
          "tip_current",
          "info",
          details("chain", chain, "validated_height", result.validatedAfter()));
    }
  }

  private static void printProgressJson(
      PrintStream out,
      String chain,
      PeerEndpoint peer,
      int iteration,
      int reconnectCount,
      int stallCount,
      IterationResult result) {
    boolean blocksCurrent =
        "blocks_current".equals(result.syncStatus()) && result.validatedAfter() >= result.headerHeight();
    String blocker = result.blockerMessage();
    String progressJson =
        "{"
            + "\"chain\":\""
            + escapeJson(chain)
            + "\",\"sync_status\":\""
            + escapeJson(result.syncStatus())
            + "\",\"header_status\":\""
            + escapeJson(result.headerStatus())
            + "\",\"header_height\":"
            + result.headerHeight()
            + ",\"validated_height\":"
            + result.validatedAfter()
            + ",\"validated_hash\":\""
            + escapeJson(result.validatedHash())
            + "\",\"stored_block_height\":"
            + result.storedBlockHeight()
            + ",\"utxo_count\":"
            + result.chainstateUtxoCount()
            + ",\"chainstate_utxo_count\":"
            + result.chainstateUtxoCount()
            + ",\"current_blocker\":"
            + (blocker == null ? "null" : "\"" + escapeJson(blocker) + "\"")
            + ",\"peer\":\""
            + escapeJson(peer.host() + ":" + peer.port())
            + "\",\"live_iteration\":"
            + iteration
            + ",\"reconnect_count\":"
            + reconnectCount
            + ",\"stall_count\":"
            + stallCount
            + ",\"restart_recovery_count\":0"
            + ",\"blocks_current\":"
            + blocksCurrent
            + ",\"downloaded_blocks\":"
            + result.downloaded()
            + ",\"connected_blocks\":"
            + result.connected()
            + "}";
    out.println("rb.port_progress " + progressJson);
    out.flush();
  }

  private static void sleep(Sleeper sleeper, long millis) throws IOException {
    if (millis <= 0) {
      return;
    }
    try {
      sleeper.sleep(millis);
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new IOException("live loop interrupted", error);
    }
  }

  private static boolean isTransientBlocker(IterationResult result) {
    return result.blockerMessage() != null
        && result.blockerMessage().startsWith("block unavailable at height ");
  }

  private static void logLiveStopAfterOpenFailure(Path dataDir, String errorMessage) {
    try (com.jbitnode.db.OperationalStore store =
        new com.jbitnode.db.RocksDbOperationalStore(dataDir.resolve("operational-rocksdb"), true)) {
      ProjectTracker tracker = new ProjectTracker(store);
      tracker.logEvent(
          "live",
          "live_stop",
          "error",
          details("reason", "chainstate_invariant", "error", errorMessage));
    } catch (Exception ignored) {
      // status output still reports the failure when best-effort event logging fails
    }
  }

  private static String details(Object... keyValues) {
    StringBuilder builder = new StringBuilder("{");
    for (int index = 0; index < keyValues.length; index += 2) {
      if (index > 0) {
        builder.append(',');
      }
      builder.append('"').append(keyValues[index]).append('"').append(':');
      Object value = keyValues[index + 1];
      if (value instanceof Number) {
        builder.append(value);
      } else {
        builder.append('"').append(String.valueOf(value).replace("\"", "'")).append('"');
      }
    }
    return builder.append('}').toString();
  }

  private static String escapeJson(String value) {
    if (value == null) {
      return "";
    }
    return value.replace("\\", "\\\\").replace("\"", "\\\"");
  }

  private record IterationResult(
      String headerStatus,
      String syncStatus,
      int validatedBefore,
      int validatedAfter,
      String validatedHash,
      int headerHeight,
      int storedBlockHeight,
      long chainstateUtxoCount,
      int downloaded,
      int connected,
      String blockerMessage) {}
}
