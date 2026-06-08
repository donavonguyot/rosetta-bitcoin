package com.jbitnode.cli;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.config.NodePaths;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.db.ChainstateMetadata;
import com.jbitnode.db.ChainstateStoreFactory;
import com.jbitnode.db.ChainstateTip;
import com.jbitnode.db.OperationalStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.RocksDbChainstateStore;
import com.jbitnode.db.RocksDbOperationalStore;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Path;
import java.sql.SQLException;

/** Builds a JSON node status summary from JavaNode's native operational stores. */
public final class DbStatusService {

  private static final ObjectMapper MAPPER = new ObjectMapper();

  private DbStatusService() {}

  public static ObjectNode summary(Path dbPath, String chain) throws SQLException, IOException {
    return summaryFromDataDir(dbPath.getParent(), chain);
  }

  public static ObjectNode summaryFromDataDir(Path dataDir, String chain)
      throws SQLException, IOException {
    try (OperationalStore operationalStore =
        new RocksDbOperationalStore(dataDir.resolve("operational-rocksdb"), false)) {
      ProjectTracker tracker = new ProjectTracker(operationalStore);
      ObjectNode root = MAPPER.createObjectNode();
      root.put("chain", chain);
      root.put("db_path", "");
      root.put("data_dir", dataDir.toString());
      root.put("native_storage", true);
      root.put("runtime_truth_backend", "rocksdb");
      root.put("rocksdb_runtime_truth", true);
      root.put("native_crypto_backend", Secp256k1.selectedBackendName());
      root.put("native_crypto_available", Secp256k1.nativeBackendAvailable());
      root.put("taproot_tweak_backend", Secp256k1.taprootTweakBackendName());
      ObjectNode sync = MAPPER.createObjectNode();
      tracker
          .getSyncState(chain)
          .ifPresentOrElse(
              state -> {
                sync.put("best_height", state.bestHeight());
                sync.put("best_hash", state.bestHash());
                sync.put("header_count", state.headerCount());
                sync.put("sync_status", state.syncStatus());
                sync.put("updated_at", state.updatedAt());
              },
              () -> sync.put("sync_status", "starting"));
      root.set("sync", sync);
      int headerCount = tracker.headerCount();
      int headerHeight = Math.max(-1, headerCount - 1);
      int storedBlockHeight = tracker.maxStoredBlockHeight(chain);
      ChainstateMetadata metadata = ChainstateStoreFactory.readMetadata(tracker, dataDir, chain);
      ChainstateTip tip = activeTip(chain, metadata);
      long activeUtxoCount = activeUtxoCount(chain, metadata);
      root.put("header_count", headerCount);
      root.put("block_count", tracker.blockCount(chain));
      root.put("header_height", headerHeight);
      root.put("header_hash", tracker.getHeaderHash(chain, headerHeight));
      root.put("stored_block_height", storedBlockHeight);
      root.put("stored_minus_validated", storedBlockHeight - tip.height());
      root.put("block_gap_count", tracker.countBlockStorageGaps(chain, Math.max(tip.height(), 0)));
      root.put("validated_height", tip.height());
      root.put("validated_hash", tip.hash() == null ? "" : tip.hash());
      root.put("utxo_accounting_policy", "core_spendable_v1");
      root.put("chainstate_backend", metadata.backendName());
      root.put("rocksdb_runtime_truth", "rocksdb".equals(metadata.backendName()));
      root.put("chainstate_backend_path", metadata.backendPath().toString());
      root.put("chainstate_status", metadata.status());
      root.put("chainstate_generation_id", metadata.generationId());
      root.put("chainstate_utxo_count", activeUtxoCount);
      root.put("utxo_count", activeUtxoCount);
      root.put("peer_count", 0);
      root.put("wire_capabilities", 0);
      root.put("schema_version", metadata.schemaVersion());
      root.put("node_version", "");
      root.putNull("current_blocker");
      root.put(
          "binary_gate_status",
          binaryGateStatus(sync.path("sync_status").asText("starting"), tip.height(), headerHeight));
      return root;
    }
  }

  public static int run(String[] args, PrintStream out) throws SQLException, IOException {
    Path dbPath = NodePaths.dbPath();
    Path dataDir = dbPath.getParent();
    String chain = NodePaths.chain();
    for (int i = 0; i < args.length; i++) {
      if (("--db".equals(args[i]) || "--data-dir".equals(args[i])) && i + 1 < args.length) {
        Path path = Path.of(args[++i]).toAbsolutePath().normalize();
        dataDir = "--db".equals(args[i - 1]) ? path.getParent() : path;
      } else if ("--chain".equals(args[i]) && i + 1 < args.length) {
        chain = args[++i];
      } else if ("--project-db".equals(args[i])) {
        throw new IOException("Project DB export moved to Project/scripts; Java status emits JSON only");
      } else if ("--node-id".equals(args[i]) && i + 1 < args.length) {
        i += 1;
      }
    }
    ObjectNode summary = summaryFromDataDir(dataDir, chain);
    out.println(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(summary));
    return 0;
  }

  private static long activeUtxoCount(String chain, ChainstateMetadata metadata)
      throws SQLException, IOException {
    if (metadata.utxoCount() >= 0) {
      return metadata.utxoCount();
    }
    if ("rocksdb".equals(metadata.backendName())) {
      try (RocksDbChainstateStore rocksDb = new RocksDbChainstateStore(metadata.backendPath(), false)) {
        Long maintained = rocksDb.readMaintainedUtxoCount();
        if (maintained != null) {
          return maintained;
        }
        return rocksDb.count(chain);
      } catch (org.rocksdb.RocksDBException error) {
        throw new IOException("failed to open RocksDB chainstate at " + metadata.backendPath(), error);
      }
    }
    return 0;
  }

  private static ChainstateTip activeTip(String chain, ChainstateMetadata metadata)
      throws SQLException, IOException {
    if ("rocksdb".equals(metadata.backendName())) {
      try (RocksDbChainstateStore rocksDb = new RocksDbChainstateStore(metadata.backendPath(), false)) {
        ChainstateTip tip = rocksDb.readTip(chain);
        if (tip != null) {
          return tip;
        }
      } catch (org.rocksdb.RocksDBException error) {
        throw new IOException("failed to open RocksDB chainstate at " + metadata.backendPath(), error);
      }
    }
    return new ChainstateTip(-1, "");
  }

  private static String binaryGateStatus(String syncStatus, int validatedHeight, int headerHeight) {
    if ("blocks_blocked".equals(syncStatus) || "error".equals(syncStatus)) {
      return "failed";
    }
    if ("blocks_current".equals(syncStatus) && headerHeight >= 0 && validatedHeight >= headerHeight) {
      return "passed";
    }
    return "not_attempted";
  }
}
