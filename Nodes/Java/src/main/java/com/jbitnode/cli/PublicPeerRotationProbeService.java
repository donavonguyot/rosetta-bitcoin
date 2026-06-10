package com.jbitnode.cli;

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
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.ChainInconsistentException;
import com.jbitnode.sync.HeaderSync;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Bounded two-peer public reconnect proof for validator-follower capability evidence. */
public final class PublicPeerRotationProbeService {

  static final int EXIT_SUCCESS = PublicPeerProbeService.EXIT_SUCCESS;
  static final int EXIT_FAIL = PublicPeerProbeService.EXIT_FAIL;
  static final int EXIT_CONFIG = PublicPeerProbeService.EXIT_CONFIG;

  private PublicPeerRotationProbeService() {}

  static int run(PrintStream out, Map<String, String> env) {
    ObjectNode result;
    try {
      com.jbitnode.consensus.secp256k1.Secp256k1.ensureNativeRuntimeBackend(env);
      String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
      ChainParams chain = ChainRegistry.get(chainName);
      List<PeerEndpoint> peers =
          PeerConfig.parsePublicRotationPeers(env.get("PUBLIC_PEERS"), chain.defaultPort());
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
      PublicPeerProbeService.writeResult(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      out.println(PublicPeerProbeService.JSON.writeValueAsString(result));
      return "pass".equals(result.path("result").asText()) ? EXIT_SUCCESS : EXIT_FAIL;
    } catch (com.jbitnode.consensus.secp256k1.Secp256k1.Secp256k1Error error) {
      result = errorResult("secp256k1_backend", error.getMessage());
      PublicPeerProbeService.writeBestEffort(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      PublicPeerProbeService.printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (IllegalArgumentException error) {
      result = errorResult("config_error", error.getMessage());
      PublicPeerProbeService.writeBestEffort(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      PublicPeerProbeService.printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (DatadirLockBusyException error) {
      result = errorResult("lock_busy", error.getMessage());
      PublicPeerProbeService.writeBestEffort(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      PublicPeerProbeService.printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (ChainInconsistentException | ChainstateInvariantException error) {
      result = errorResult("chainstate_error", error.getMessage());
      PublicPeerProbeService.writeBestEffort(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      PublicPeerProbeService.printBestEffort(out, result);
      return EXIT_CONFIG;
    } catch (Exception error) {
      result = errorResult("probe_error", error.getMessage());
      PublicPeerProbeService.writeBestEffort(env.get("PUBLIC_ROTATION_RESULT_PATH"), result);
      PublicPeerProbeService.printBestEffort(out, result);
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
    List<ObjectNode> successes = new ArrayList<>();
    int failures = 0;

    try (ChainstateSession session =
        ChainstateSession.openReadWrite(dataDir, dbPath, chain, env, requireBackendAligned)) {
      ProjectTracker tracker = session.tracker();
      for (PeerEndpoint peer : peers) {
        ObjectNode attempt =
            PublicPeerProbeService.attemptPeer(
                chain, session, tracker, peer, maxHeaders, maxBatches, maxBlocks);
        attempts.add(attempt);
        if (isPassingAttempt(attempt) && !containsPeer(successes, attempt.path("peer").asText())) {
          successes.add(attempt);
          if (successes.size() == 2) {
            summarizePass(root, successes, failures);
            return root;
          }
        } else {
          failures += 1;
        }
      }
    }

    root.put("result", "fail");
    root.put("final_status", "peer_rotation_probe_failed");
    root.put("disconnect_error_count", failures);
    root.put("reconnect_count", 0);
    root.put("successful_peer_count", successes.size());
    return root;
  }

  static boolean isPassingAttempt(ObjectNode attempt) {
    return "pass".equals(attempt.path("result").asText())
        && attempt.hasNonNull("peer")
        && attempt.path("current_blocker").isNull();
  }

  static boolean containsPeer(List<ObjectNode> attempts, String peer) {
    String key = normalizePeer(peer);
    for (ObjectNode attempt : attempts) {
      if (normalizePeer(attempt.path("peer").asText()).equals(key)) {
        return true;
      }
    }
    return false;
  }

  static boolean hasTwoDistinctPassingPeers(List<ObjectNode> attempts) {
    List<ObjectNode> passing = new ArrayList<>();
    for (ObjectNode attempt : attempts) {
      if (isPassingAttempt(attempt) && !containsPeer(passing, attempt.path("peer").asText())) {
        passing.add(attempt);
      }
    }
    return passing.size() >= 2;
  }

  private static void summarizePass(ObjectNode root, List<ObjectNode> successes, int failures) {
    ObjectNode first = successes.get(0);
    ObjectNode second = successes.get(1);
    ArrayNode selected = root.putArray("selected_peers");
    selected.add(first.path("peer").asText());
    selected.add(second.path("peer").asText());
    root.put("result", "pass");
    root.put("final_status", "peer_rotation_probe_pass");
    root.put("disconnect_error_count", failures);
    root.put("reconnect_count", 1);
    root.put("successful_peer_count", successes.size());
    copy(root, first, "start_header_height");
    copy(root, second, "end_header_height");
    copy(root, first, "start_validated_height");
    copy(root, first, "start_validated_hash");
    copy(root, second, "end_validated_height");
    copy(root, second, "end_validated_hash");
    root.put("blocks_downloaded", sum(successes, "blocks_downloaded"));
    root.put("blocks_connected", sum(successes, "blocks_connected"));
    root.set("first_peer", first.deepCopy());
    root.set("second_peer", second.deepCopy());
  }

  private static int sum(List<ObjectNode> attempts, String key) {
    int total = 0;
    for (ObjectNode attempt : attempts) {
      total += attempt.path(key).asInt(0);
    }
    return total;
  }

  private static void copy(ObjectNode root, ObjectNode source, String key) {
    if (source.has(key)) {
      root.set(key, source.get(key));
    } else {
      root.putNull(key);
    }
  }

  private static String normalizePeer(String peer) {
    return peer.trim().toLowerCase(Locale.ROOT);
  }

  private static ObjectNode baseResult() {
    ObjectNode root = PublicPeerProbeService.JSON.createObjectNode();
    root.put("schema", "java.public_peer_rotation_probe.v1");
    root.put("port", "java");
    root.put("capability", "full_node_peer_rotation_reconnect");
    root.put("captured_at", Instant.now().toString());
    root.put("scope", "docker_public_peer");
    root.put("byte_source", "public_testnet4_p2p");
    root.put("proof_mode", "peer_rotation_probe");
    root.put("peer_mode", "external_manual");
    root.put("fresh_state", false);
    root.put(
        "does_not_prove",
        "Manual two-peer outbound rotation does not prove inbound serving, mempool relay, DNS seed selection, reorg recovery, restart soak, bad-peer safety, or resource-bound safety.");
    return root;
  }

  private static ObjectNode errorResult(String status, String message) {
    ObjectNode root = baseResult();
    root.put("result", "fail");
    root.put("final_status", status);
    root.put("error", message == null ? "" : message);
    root.putArray("attempted_peers");
    root.putArray("selected_peers");
    root.put("disconnect_error_count", 0);
    root.put("reconnect_count", 0);
    return root;
  }
}
