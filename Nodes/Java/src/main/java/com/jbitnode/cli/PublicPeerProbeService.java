package com.jbitnode.cli;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.config.NodePaths;
import com.jbitnode.config.PeerConfig;
import com.jbitnode.config.PeerConfig.PeerEndpoint;
import com.jbitnode.db.ChainstateInvariantException;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.BlockSync;
import com.jbitnode.sync.ChainInconsistentException;
import com.jbitnode.sync.HeaderSync;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/** Bounded public-peer probe for outbound testnet4 participation evidence. */
public final class PublicPeerProbeService {

  static final int EXIT_SUCCESS = 0;
  static final int EXIT_FAIL = 1;
  static final int EXIT_CONFIG = 2;

  static final ObjectMapper JSON =
      new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

  private PublicPeerProbeService() {}

  static int run(PrintStream out, Map<String, String> env) {
    ObjectNode result;
    try {
      com.jbitnode.consensus.secp256k1.Secp256k1.ensureNativeRuntimeBackend(env);
      String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
      ChainParams chain = ChainRegistry.get(chainName);
      List<PeerEndpoint> peers = PeerConfig.parsePublicPeers(env.get("PUBLIC_PEERS"), chain.defaultPort());
      int maxHeaders =
          PeerConfig.parseIntValue(env.get("HEADERS_MAX"), HeaderSync.DEFAULT_MAX_HEADERS);
      int maxBatches =
          PeerConfig.parseIntValue(
              env.get("HEADER_BATCHES_MAX"), HeaderSync.DEFAULT_HEADER_BATCHES_MAX);
      int maxBlocks = PeerConfig.parseIntValue(env.get("BLOCKS_MAX"), 64);
      boolean requireBackendAligned =
          PeerConfig.parseBoolean(env.get("REQUIRE_ROCKSDB_ALIGNED"), true);

      Path dbPath = NodePaths.dbPathFromEnv(env.get("DATA_DIR"), env.get("DB_PATH"));
      Path dataDir = dbPath.getParent();
      result =
          runProbe(
              chain,
              dataDir,
              dbPath,
              env,
              requireBackendAligned,
              peers,
              maxHeaders,
              maxBatches,
              maxBlocks);
      writeResult(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      out.println(JSON.writeValueAsString(result));
      return "pass".equals(result.path("result").asText()) ? EXIT_SUCCESS : EXIT_FAIL;
    } catch (com.jbitnode.consensus.secp256k1.Secp256k1.Secp256k1Error error) {
      result = errorResult("secp256k1_backend", error.getMessage());
      writeBestEffort(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (IllegalArgumentException error) {
      result = errorResult("config_error", error.getMessage());
      writeBestEffort(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (DatadirLockBusyException error) {
      result = errorResult("lock_busy", error.getMessage());
      writeBestEffort(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (ChainInconsistentException | ChainstateInvariantException error) {
      result = errorResult("chainstate_error", error.getMessage());
      writeBestEffort(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (Exception error) {
      result = errorResult("probe_error", error.getMessage());
      writeBestEffort(env.get("PUBLIC_PROBE_RESULT_PATH"), result);
      printBestEffort(out, result);
      return EXIT_FAIL;
    }
  }

  private static ObjectNode runProbe(
      ChainParams chain,
      Path dataDir,
      Path dbPath,
      Map<String, String> env,
      boolean requireBackendAligned,
      List<PeerEndpoint> peers,
      int maxHeaders,
      int maxBatches,
      int maxBlocks)
      throws IOException, SQLException, DatadirLockBusyException, ChainstateInvariantException,
          ChainInconsistentException {
    ObjectNode root = baseResult();
    root.put("chain", chain.name());
    root.put("max_headers", maxHeaders);
    root.put("max_header_batches", maxBatches);
    root.put("max_blocks", maxBlocks);
    ArrayNode attempts = root.putArray("attempted_peers");
    int errors = 0;

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(dataDir, dbPath, chain, env, requireBackendAligned)) {
      ProjectTracker tracker = session.tracker();
      for (PeerEndpoint peer : peers) {
        ObjectNode attempt = attemptPeer(chain, session, tracker, peer, maxHeaders, maxBatches, maxBlocks);
        attempts.add(attempt);
        if ("pass".equals(attempt.path("result").asText())) {
          root.put("result", "pass");
          root.put("selected_peer", peer.host() + ":" + peer.port());
          copyPublicFields(root, attempt);
          root.put("disconnect_error_count", errors);
          root.put(
              "final_status",
              attempt.path("final_sync_status").asText("public_peer_probe_pass"));
          return root;
        }
        errors += 1;
      }
    }

    root.put("result", "fail");
    root.putNull("selected_peer");
    root.put("disconnect_error_count", errors);
    root.put("final_status", "public_peer_probe_failed");
    return root;
  }

  static ObjectNode attemptPeer(
      ChainParams chain,
      ChainstateSession session,
      ProjectTracker tracker,
      PeerEndpoint peer,
      int maxHeaders,
      int maxBatches,
      int maxBlocks) {
    ObjectNode attempt = JSON.createObjectNode();
    attempt.put("peer", peer.host() + ":" + peer.port());
    try {
      int localStartHeight = tracker.bootstrapStartHeight(chain.name());
      int startHeaderHeight = headerHeight(tracker, chain.name());
      int startValidatedHeight = tracker.getValidatedHeight(chain.name());
      String startValidatedHash = tracker.getValidatedHash(chain.name());
      attempt.put("local_advertised_start_height", localStartHeight);
      attempt.put("start_header_height", startHeaderHeight);
      attempt.put("start_validated_height", startValidatedHeight);
      putNullable(attempt, "start_validated_hash", startValidatedHash);

      try (PeerConnection connection =
          new PeerConnection(peer.host(), peer.port(), chain, tracker, localStartHeight)) {
        connection.connect();
        int peerAdvertisedHeight =
            connection.remoteVersion() != null ? connection.remoteVersion().startHeight() : -1;
        attempt.put("peer_advertised_start_height", peerAdvertisedHeight);
        HeaderSync.Result headerResult =
            HeaderSync.syncFromPeer(connection, chain, tracker, maxHeaders, maxBatches);
        BlockSync.Result blockResult =
            BlockSync.syncFromPeer(
                connection,
                chain,
                tracker,
                session.blockStorage(),
                session.chainstateStore(),
                maxBlocks,
                BlockSync.TimingSink.none(),
                false);
        int endHeaderHeight = headerHeight(tracker, chain.name());
        int endValidatedHeight = tracker.getValidatedHeight(chain.name());
        String endValidatedHash = tracker.getValidatedHash(chain.name());
        ChainstateStatus chainstateStatus =
            ChainstateStatus.capture(session.chainstateStore(), chain.name());

        attempt.put("end_header_height", endHeaderHeight);
        attempt.put("end_validated_height", endValidatedHeight);
        putNullable(attempt, "end_validated_hash", endValidatedHash);
        attempt.put("blocks_downloaded", blockResult.downloaded());
        attempt.put("blocks_connected", blockResult.connected());
        attempt.put("header_sync_status", headerResult.syncStatus());
        attempt.put("block_sync_status", blockResult.syncStatus());
        attempt.put("final_sync_status", blockResult.syncStatus());
        attempt.put("chainstate_utxo_count", chainstateStatus.backendUtxoCount());
        putNullable(attempt, "current_blocker", blockResult.blockerMessage());

        boolean pass =
            successfulPublicParticipation(
                startHeaderHeight,
                startValidatedHeight,
                endHeaderHeight,
                endValidatedHeight,
                peerAdvertisedHeight,
                blockResult);
        attempt.put("result", pass ? "pass" : "fail");
        if (!pass && blockResult.blockerMessage() == null) {
          attempt.put(
              "failure",
              "peer did not reach a near-current public participation state within the bounded probe");
        }
      }
    } catch (Exception error) {
      attempt.put("result", "fail");
      attempt.put("error", error.getMessage());
    }
    return attempt;
  }

  static boolean successfulPublicParticipation(
      int startHeaderHeight,
      int startValidatedHeight,
      int endHeaderHeight,
      int endValidatedHeight,
      int peerAdvertisedHeight,
      BlockSync.Result blockResult) {
    if (peerAdvertisedHeight < 0 || blockResult.blockerMessage() != null) {
      return false;
    }
    boolean peerNotStale = peerAdvertisedHeight >= startHeaderHeight - HeaderSync.NEAR_PEER_TIP;
    boolean headersNearPeer = endHeaderHeight >= peerAdvertisedHeight - HeaderSync.NEAR_PEER_TIP;
    boolean noNewBlockNeeded = endHeaderHeight <= startValidatedHeight + HeaderSync.NEAR_PEER_TIP;
    boolean connectedAdvertisedBlocks =
        blockResult.connected() > 0 || endValidatedHeight >= endHeaderHeight - HeaderSync.NEAR_PEER_TIP;
    return peerNotStale && headersNearPeer && (noNewBlockNeeded || connectedAdvertisedBlocks);
  }

  private static int headerHeight(ProjectTracker tracker, String chain) throws SQLException {
    return tracker.getSyncState(chain).map(ProjectTracker.SyncState::bestHeight).orElse(0);
  }

  private static ObjectNode baseResult() {
    ObjectNode root = JSON.createObjectNode();
    root.put("schema", "java.public_peer_probe.v1");
    root.put("port", "java");
    root.put("capability", "full_node_public_peer_sync_probe");
    root.put("captured_at", Instant.now().toString());
    root.put("scope", "docker_public_peer");
    root.put("byte_source", "public_testnet4_p2p");
    root.put("proof_mode", "public_peer_probe");
    root.put("peer_mode", "external_manual");
    root.put("fresh_state", false);
    root.put(
        "does_not_prove",
        "Outbound public-peer probe does not prove inbound serving, mempool relay, reorg recovery, restart soak, bad-peer safety, resource-bound safety, or peer rotation.");
    return root;
  }

  private static ObjectNode errorResult(String status, String message) {
    ObjectNode root = baseResult();
    root.put("result", "fail");
    root.put("final_status", status);
    root.put("error", message == null ? "" : message);
    root.putArray("attempted_peers");
    root.put("disconnect_error_count", 0);
    root.putNull("selected_peer");
    return root;
  }

  private static void copyPublicFields(ObjectNode root, ObjectNode attempt) {
    for (String key :
        List.of(
            "peer_advertised_start_height",
            "local_advertised_start_height",
            "start_header_height",
            "end_header_height",
            "start_validated_height",
            "start_validated_hash",
            "end_validated_height",
            "end_validated_hash",
            "blocks_downloaded",
            "blocks_connected",
            "chainstate_utxo_count",
            "current_blocker")) {
      if (attempt.has(key)) {
        root.set(key, attempt.get(key));
      } else {
        root.putNull(key);
      }
    }
  }

  static void putNullable(ObjectNode node, String key, String value) {
    if (value == null) {
      node.putNull(key);
    } else {
      node.put(key, value);
    }
  }

  static void writeResult(String rawPath, ObjectNode result) throws IOException {
    if (rawPath == null || rawPath.isBlank()) {
      return;
    }
    Path path = Path.of(rawPath);
    if (path.getParent() != null) {
      Files.createDirectories(path.getParent());
    }
    Files.writeString(path, JSON.writeValueAsString(result) + System.lineSeparator(), StandardCharsets.UTF_8);
  }

  static void writeBestEffort(String rawPath, ObjectNode result) {
    try {
      writeResult(rawPath, result);
    } catch (IOException ignored) {
      // Preserve the probe's original failure.
    }
  }

  static void printBestEffort(PrintStream out, ObjectNode result) {
    try {
      out.println(JSON.writeValueAsString(result));
    } catch (IOException ignored) {
      out.println("{\"schema\":\"java.public_peer_probe.v1\",\"result\":\"fail\"}");
    }
  }
}
