package com.jbitnode.cli;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.config.NodePaths;
import com.jbitnode.config.PeerConfig;
import com.jbitnode.config.PeerConfig.PeerEndpoint;
import com.jbitnode.db.ChainstateInvariantException;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.OperationalStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.RocksDbOperationalStore;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.BlockSync;
import com.jbitnode.sync.ChainInconsistentException;
import com.jbitnode.sync.HeaderSync;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Path;
import java.sql.SQLException;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicBoolean;

/** Local Core header sync CLI (`make java-node-sync-local-core`). */
public final class SyncLocalCoreService {

  static final int EXIT_BLOCKED = 4;

  private SyncLocalCoreService() {}

  public static int run(PrintStream out) {
    return run(out, System.getenv());
  }

  static int run(PrintStream out, java.util.Map<String, String> env) {
    try {
      com.jbitnode.consensus.secp256k1.Secp256k1.ensureNativeRuntimeBackend(env);
    } catch (com.jbitnode.consensus.secp256k1.Secp256k1.Secp256k1Error error) {
      out.println("  sync_status=error");
      out.println("  error=" + error.getMessage());
      out.println("  binary_gate_status=not_attempted");
      printExitSummary(out, 2, null, -1, "error");
      return 2;
    }
    String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
    ChainParams chain = ChainRegistry.get(chainName);
    List<PeerEndpoint> peers =
        PeerConfig.parsePeers(env.get("PEERS"), chain.defaultPort());
    int maxHeaders = PeerConfig.parseIntValue(env.get("HEADERS_MAX"), HeaderSync.DEFAULT_MAX_HEADERS);
    int maxBatches =
        PeerConfig.parseIntValue(env.get("HEADER_BATCHES_MAX"), HeaderSync.DEFAULT_HEADER_BATCHES_MAX);
    int maxBlocks = PeerConfig.parseIntValue(env.get("BLOCKS_MAX"), 64);
    boolean skipBlocks = PeerConfig.parseBoolean(env.get("SKIP_BLOCKS"), false);
    boolean syncTiming = PeerConfig.parseBoolean(env.get("SYNC_TIMING"), false);
    boolean progressJson = PeerConfig.parseBoolean(env.get("PROGRESS_JSON"), false);
    int progressInterval = Math.max(1, PeerConfig.parseIntValue(env.get("PROGRESS_INTERVAL"), 250));

    Path dbPath = NodePaths.dbPathFromEnv(env.get("DATA_DIR"), env.get("DB_PATH"));
    Path dataDir = dbPath.getParent();

    PeerEndpoint peer = peers.getFirst();
    out.println("jbitnode sync-local-core");
    out.println("  chain=" + chain.name());
    out.println("  db=(native-rocksdb)");
    out.println("  peer=" + peer.host() + ":" + peer.port());
    out.println("  headers_max=" + maxHeaders + " batches_max=" + maxBatches);
    out.println("  blocks_max=" + maxBlocks + " skip_blocks=" + skipBlocks);

    AtomicBoolean completedNormally = new AtomicBoolean(false);
    Thread shutdownHook =
        new Thread(
            () -> {
              if (!completedNormally.get()) {
                markStalledNative(dataDir, chain.name(), "abnormal_exit");
              }
            },
            "SyncLocalCore-stall-marker");
    Runtime.getRuntime().addShutdownHook(shutdownHook);

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(dataDir, dbPath, chain, env, true)) {
      ProjectTracker tracker = session.tracker();
      int startHeight = tracker.bootstrapStartHeight(chain.name());
      try (PeerConnection connection =
          new PeerConnection(peer.host(), peer.port(), chain, tracker, startHeight)) {
        out.println("  utxo_backend=" + session.chainstateStore().backend());
        connection.connect();
        HeaderSync.Result headerResult =
            HeaderSync.syncFromPeer(connection, chain, tracker, maxHeaders, maxBatches);
        out.println("  stored_headers=" + headerResult.storedTotal());
        out.println("  header_height=" + headerResult.bestHeight());
        out.println("  sync_status=" + headerResult.syncStatus());

        BlockSync.Result blockResult = null;
        if (!skipBlocks) {
          blockResult =
              BlockSync.syncFromPeer(
                  connection,
                  chain,
                  tracker,
                  session.blockStorage(),
                  session.chainstateStore(),
                  maxBlocks,
                  BlockSync.TimingSink.none(),
                  false,
                  progressJson
                      ? progress ->
                          printProgressJson(
                              out,
                              chain.name(),
                              headerResult.bestHeight(),
                              session.chainstateStore(),
                              progress,
                              progressInterval)
                      : BlockSync.ProgressSink.none());
          out.println("  downloaded_blocks=" + blockResult.downloaded());
          out.println("  connected_blocks=" + blockResult.connected());
          out.println("  sync_status=" + blockResult.syncStatus());
          if (syncTiming) {
            printTimingSummary(out, blockResult.timingSummary());
          }
          if (blockResult.blockerMessage() != null) {
            out.println("  current_blocker=" + blockResult.blockerMessage());
          }
        }

        int validatedHeight = tracker.getValidatedHeight(chain.name());
        out.println("  validated_height=" + validatedHeight);
        ChainstateStatus chainstateStatus =
            ChainstateStatus.capture(session.chainstateStore(), chain.name());
        out.println("  utxo_count=" + chainstateStatus.backendUtxoCount());
        chainstateStatus.print(out);
        out.println("  binary_gate_status=not_attempted");

        String finalSyncStatus =
            blockResult != null ? blockResult.syncStatus() : headerResult.syncStatus();
        int exitCode = exitCodeForSyncStatus(finalSyncStatus);
        printExitSummary(out, exitCode, blockResult, validatedHeight, finalSyncStatus);
        completedNormally.set(true);
        removeShutdownHookQuietly(shutdownHook);
        return exitCode;
      }
    } catch (DatadirLockBusyException e) {
      completedNormally.set(true);
      removeShutdownHookQuietly(shutdownHook);
      out.println("  sync_status=error");
      out.println("  error=" + e.getMessage());
      out.println("  binary_gate_status=not_attempted");
      printExitSummary(out, 2, null, -1, "error");
      return 2;
    } catch (ChainInconsistentException | ChainstateInvariantException e) {
      completedNormally.set(true);
      removeShutdownHookQuietly(shutdownHook);
      out.println("  sync_status=error");
      out.println("  error=" + e.getMessage());
      out.println("  binary_gate_status=not_attempted");
      printExitSummary(out, 3, null, -1, "error");
      return 3;
    } catch (IOException e) {
      completedNormally.set(true);
      removeShutdownHookQuietly(shutdownHook);
      out.println("  sync_status=error");
      out.println("  error=" + e.getMessage());
      out.println("  binary_gate_status=not_attempted");
      printExitSummary(out, 1, null, -1, "error");
      return 1;
    } catch (SQLException e) {
      completedNormally.set(true);
      removeShutdownHookQuietly(shutdownHook);
      out.println("  sync_status=error");
      out.println("  error=" + e.getMessage());
      out.println("  binary_gate_status=not_attempted");
      printExitSummary(out, 1, null, -1, "error");
      return 1;
    }
  }

  static int exitCodeForSyncStatus(String syncStatus) {
    if ("blocks_blocked".equals(syncStatus)) {
      return EXIT_BLOCKED;
    }
    return 0;
  }

  static void printExitSummary(
      PrintStream out,
      int exitCode,
      BlockSync.Result blockResult,
      int validatedHeight,
      String syncStatus) {
    int downloaded = blockResult != null ? blockResult.downloaded() : 0;
    int connected = blockResult != null ? blockResult.connected() : 0;
    out.println(
        "sync_exit_summary exit_code="
            + exitCode
            + " sync_status="
            + syncStatus
            + " validated_height="
            + validatedHeight
            + " connected="
            + connected
            + " downloaded="
            + downloaded);
  }

  static void printTimingSummary(PrintStream out, BlockSync.TimingSummary summary) {
    if (summary == null || summary.connectedBlocks() == 0) {
      return;
    }
    out.println(
        "sync_timing_summary connected="
            + summary.connectedBlocks()
            + " total_block_download_wait_ms="
            + summary.totalMillis("block_download_wait")
            + " avg_block_download_wait_ms="
            + summary.averageMillis("block_download_wait")
            + " total_block_parse_validate_ms="
            + summary.totalMillis("block_parse_validate")
            + " avg_block_parse_validate_ms="
            + summary.averageMillis("block_parse_validate")
            + " total_txid_hashing_ms="
            + summary.totalMillis("txid_hashing")
            + " avg_txid_hashing_ms="
            + summary.averageMillis("txid_hashing")
            + " total_prevout_prepare_ms="
            + summary.totalMillis("prevout_prepare")
            + " avg_prevout_prepare_ms="
            + summary.averageMillis("prevout_prepare")
            + " total_utxo_load_ms="
            + summary.totalMillis("utxo_load")
            + " avg_utxo_load_ms="
            + summary.averageMillis("utxo_load")
            + " total_script_verify_ms="
            + summary.totalMillis("script_verify")
            + " avg_script_verify_ms="
            + summary.averageMillis("script_verify")
            + " total_script_runner_wait_ms="
            + summary.totalMillis("script_runner_wait")
            + " avg_script_runner_wait_ms="
            + summary.averageMillis("script_runner_wait")
            + " total_script_sighash_cache_build_ms="
            + summary.totalMillis("script_sighash_cache_build")
            + " avg_script_sighash_cache_build_ms="
            + summary.averageMillis("script_sighash_cache_build")
            + " total_script_sighash_legacy_ms="
            + summary.totalMillis("script_sighash_legacy")
            + " avg_script_sighash_legacy_ms="
            + summary.averageMillis("script_sighash_legacy")
            + " total_script_sighash_witness_ms="
            + summary.totalMillis("script_sighash_witness")
            + " avg_script_sighash_witness_ms="
            + summary.averageMillis("script_sighash_witness")
            + " total_script_sighash_taproot_ms="
            + summary.totalMillis("script_sighash_taproot")
            + " avg_script_sighash_taproot_ms="
            + summary.averageMillis("script_sighash_taproot")
            + " total_script_ecdsa_verify_ms="
            + summary.totalMillis("script_ecdsa_verify")
            + " avg_script_ecdsa_verify_ms="
            + summary.averageMillis("script_ecdsa_verify")
            + " total_script_schnorr_verify_ms="
            + summary.totalMillis("script_schnorr_verify")
            + " avg_script_schnorr_verify_ms="
            + summary.averageMillis("script_schnorr_verify")
            + " total_script_interpreter_eval_ms="
            + summary.totalMillis("script_interpreter_eval")
            + " avg_script_interpreter_eval_ms="
            + summary.averageMillis("script_interpreter_eval")
            + " total_script_pubkey_decode_or_lift_ms="
            + summary.totalMillis("script_pubkey_decode_or_lift")
            + " avg_script_pubkey_decode_or_lift_ms="
            + summary.averageMillis("script_pubkey_decode_or_lift")
            + " total_script_taproot_dispatch_ms="
            + summary.totalMillis("script_taproot_dispatch")
            + " avg_script_taproot_dispatch_ms="
            + summary.averageMillis("script_taproot_dispatch")
            + " total_script_taproot_key_path_ms="
            + summary.totalMillis("script_taproot_key_path")
            + " avg_script_taproot_key_path_ms="
            + summary.averageMillis("script_taproot_key_path")
            + " total_script_taproot_script_path_ms="
            + summary.totalMillis("script_taproot_script_path")
            + " avg_script_taproot_script_path_ms="
            + summary.averageMillis("script_taproot_script_path")
            + " total_script_taproot_control_parse_ms="
            + summary.totalMillis("script_taproot_control_parse")
            + " avg_script_taproot_control_parse_ms="
            + summary.averageMillis("script_taproot_control_parse")
            + " total_script_taproot_tweak_verify_ms="
            + summary.totalMillis("script_taproot_tweak_verify")
            + " avg_script_taproot_tweak_verify_ms="
            + summary.averageMillis("script_taproot_tweak_verify")
            + " total_script_taproot_stack_setup_ms="
            + summary.totalMillis("script_taproot_stack_setup")
            + " avg_script_taproot_stack_setup_ms="
            + summary.averageMillis("script_taproot_stack_setup")
            + " total_script_stack_setup_ms="
            + summary.totalMillis("script_stack_setup")
            + " avg_script_stack_setup_ms="
            + summary.averageMillis("script_stack_setup")
            + " total_output_create_ms="
            + summary.totalMillis("output_create")
            + " avg_output_create_ms="
            + summary.averageMillis("output_create")
            + " total_undo_capture_ms="
            + summary.totalMillis("undo_capture")
            + " avg_undo_capture_ms="
            + summary.averageMillis("undo_capture")
            + " total_utxo_spend_list_build_ms="
            + summary.totalMillis("utxo_spend_list_build")
            + " avg_utxo_spend_list_build_ms="
            + summary.averageMillis("utxo_spend_list_build")
            + " total_utxo_spend_batch_ms="
            + summary.totalMillis("utxo_spend_batch")
            + " avg_utxo_spend_batch_ms="
            + summary.averageMillis("utxo_spend_batch")
            + " total_utxo_add_list_build_ms="
            + summary.totalMillis("utxo_add_list_build")
            + " avg_utxo_add_list_build_ms="
            + summary.averageMillis("utxo_add_list_build")
            + " total_utxo_delete_prepare_ms="
            + summary.totalMillis("utxo_delete_prepare")
            + " avg_utxo_delete_prepare_ms="
            + summary.averageMillis("utxo_delete_prepare")
            + " total_utxo_put_prepare_ms="
            + summary.totalMillis("utxo_put_prepare")
            + " avg_utxo_put_prepare_ms="
            + summary.averageMillis("utxo_put_prepare")
            + " total_undo_put_prepare_ms="
            + summary.totalMillis("undo_put_prepare")
            + " avg_undo_put_prepare_ms="
            + summary.averageMillis("undo_put_prepare")
            + " total_metadata_put_prepare_ms="
            + summary.totalMillis("metadata_put_prepare")
            + " avg_metadata_put_prepare_ms="
            + summary.averageMillis("metadata_put_prepare")
            + " total_rocksdb_write_ms="
            + summary.totalMillis("rocksdb_write")
            + " avg_rocksdb_write_ms="
            + summary.averageMillis("rocksdb_write")
            + " total_utxo_add_batch_ms="
            + summary.totalMillis("utxo_add_batch")
            + " avg_utxo_add_batch_ms="
            + summary.averageMillis("utxo_add_batch")
            + " total_utxo_apply_ms="
            + summary.totalMillis("utxo_apply")
            + " avg_utxo_apply_ms="
            + summary.averageMillis("utxo_apply")
            + " total_utxo_undo_replace_ms="
            + summary.totalMillis("utxo_undo_replace")
            + " avg_utxo_undo_replace_ms="
            + summary.averageMillis("utxo_undo_replace")
            + " total_utxo_undo_delete_ms="
            + summary.totalMillis("utxo_undo_delete")
            + " avg_utxo_undo_delete_ms="
            + summary.averageMillis("utxo_undo_delete")
            + " total_utxo_undo_insert_batch_ms="
            + summary.totalMillis("utxo_undo_insert_batch")
            + " avg_utxo_undo_insert_batch_ms="
            + summary.averageMillis("utxo_undo_insert_batch")
            + " total_tip_update_ms="
            + summary.totalMillis("tip_update")
            + " avg_tip_update_ms="
            + summary.averageMillis("tip_update")
            + " total_block_store_ms="
            + summary.totalMillis("block_store")
            + " avg_block_store_ms="
            + summary.averageMillis("block_store")
            + " total_commit_ms="
            + summary.totalMillis("commit")
            + " avg_commit_ms="
            + summary.averageMillis("commit")
            + " total_block_connect_store_commit_ms="
            + summary.totalMillis("block_connect_store_commit")
            + " avg_block_connect_store_commit_ms="
            + summary.averageMillis("block_connect_store_commit"));
    int rank = 1;
    for (BlockSync.SlowBlock block : summary.slowBlocks()) {
      out.println(
          "sync_slow_block rank="
              + rank
              + " height="
              + block.height()
              + " block_size="
              + block.blockSize()
              + " input_count="
              + block.inputCount()
              + " tx_count="
              + block.txCount()
              + " vin_count="
              + block.vinCount()
              + " vout_count="
              + block.voutCount()
              + " script_input_count="
              + block.scriptInputCount()
              + " input_shape_counts="
              + mapJson(block.inputShapeCounts())
              + " spent_prevout_script_types="
              + mapJson(block.spentPrevoutScriptTypes())
              + " output_script_types="
              + mapJson(block.outputScriptTypes())
              + " utxo_load_ms="
              + block.utxoLoadMillis()
              + " script_verify_ms="
              + block.scriptVerifyMillis()
              + " utxo_apply_ms="
              + block.utxoApplyMillis()
              + " commit_ms="
              + block.commitMillis()
              + " block_connect_store_commit_ms="
              + block.blockConnectStoreCommitMillis());
      rank += 1;
    }
  }

  static void printProgressJson(
      PrintStream out,
      String chain,
      int headerHeight,
      com.jbitnode.db.ChainstateStore chainstateStore,
      BlockSync.Progress progress,
      int progressInterval)
      throws SQLException {
    if (progress.height() != 1 && progress.height() % progressInterval != 0) {
      return;
    }
    ChainstateStatus chainstateStatus = ChainstateStatus.capture(chainstateStore, chain);
    String progressJson =
        "{"
            + "\"chain\":\""
            + escapeJson(chain)
            + "\",\"sync_status\":\""
            + escapeJson(progress.syncStatus())
            + "\",\"header_height\":"
            + headerHeight
            + ",\"validated_height\":"
            + progress.height()
            + ",\"validated_hash\":\""
            + escapeJson(progress.hash())
            + "\",\"stored_block_height\":"
            + progress.height()
            + ",\"utxo_count\":"
            + chainstateStatus.backendUtxoCount()
            + ",\"chainstate_utxo_count\":"
            + chainstateStatus.backendUtxoCount()
            + ",\"current_blocker\":null"
            + ",\"downloaded_blocks\":"
            + progress.downloaded()
            + ",\"connected_blocks\":"
            + progress.connected()
            + "}";
    out.println("sync_progress_json=" + progressJson);
    out.println("rb.port_progress " + progressJson);
    out.flush();
  }

  static void markStalledNative(Path dataDir, String chain, String exitReason) {
    try (OperationalStore store = new RocksDbOperationalStore(dataDir.resolve("operational-rocksdb"), true)) {
      ProjectTracker tracker = new ProjectTracker(store);
      tracker.upsertSyncState(
          chain, new ProjectTracker.SyncStatePatch(null, null, null, "blocks_stalled"));
      int height = tracker.getValidatedHeight(chain);
      tracker.logEvent(
          "sync",
          "SyncLocalCore exited",
          "warning",
          "{\"exit_reason\":\""
              + escapeJson(exitReason)
              + "\",\"validated_height\":"
              + height
              + "}");
    } catch (SQLException | IOException ignored) {
      // Best-effort when the JVM is shutting down.
    }
  }

  static void markStalled(Path dataDir, String chain, String exitReason) {
    markStalledNative(dataDir, chain, exitReason);
  }

  private static String escapeJson(String value) {
    return value.replace("\\", "\\\\").replace("\"", "\\\"");
  }

  private static String mapJson(Map<String, Integer> values) {
    StringBuilder json = new StringBuilder("{");
    boolean first = true;
    for (Map.Entry<String, Integer> entry : new TreeMap<>(values).entrySet()) {
      if (!first) {
        json.append(",");
      }
      json.append("\"")
          .append(escapeJson(entry.getKey()))
          .append("\":")
          .append(entry.getValue());
      first = false;
    }
    json.append("}");
    return json.toString();
  }

  private static void removeShutdownHookQuietly(Thread hook) {
    try {
      Runtime.getRuntime().removeShutdownHook(hook);
    } catch (IllegalStateException ignored) {
      // Hook already running during shutdown.
    }
  }
}
