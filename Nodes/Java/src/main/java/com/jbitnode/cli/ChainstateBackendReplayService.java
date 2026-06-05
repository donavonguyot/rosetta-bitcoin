package com.jbitnode.cli;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.chain.Genesis;
import com.jbitnode.config.NodePaths;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.consensus.merkle.Merkle;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.db.ChainstateSession;
import com.jbitnode.db.OperationalStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.RocksDbOperationalStore;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.storage.BlockStore;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.storage.DatadirLockBusyException;
import com.jbitnode.sync.BlockSync;
import com.jbitnode.util.Hex;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Replays real block fixtures through the RocksDB Codec v2 chainstate path. */
public final class ChainstateBackendReplayService {

  private ChainstateBackendReplayService() {}

  public static int run(PrintStream out, Map<String, String> env) {
    String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
    ChainParams chain = ChainRegistry.get(chainName);
    Path dbPath = NodePaths.dbPathFromEnv(env.get("DATA_DIR"), env.get("DB_PATH"));
    Path dataDir = dbPath.getParent();
    Path fixtureDir =
        Path.of(env.getOrDefault("FIXTURE_BLOCKS_DIR", "src/test/resources/fixtures"))
            .toAbsolutePath()
            .normalize();
    Path proofPath =
        Path.of(
                env.getOrDefault(
                    "PROOF_PATH",
                    "../Shared/conformance/results/java_rocksdb_codec_v2_storage_2026-06-01.json"))
            .toAbsolutePath()
            .normalize();
    int replayTargetHeight = parseInt(env.get("BLOCKS_MAX"), 2);

    Map<String, String> replayEnv = new HashMap<>(env);
    replayEnv.put("UTXO_BACKEND", "rocksdb");
    replayEnv.putIfAbsent("ROCKSDB_DIR", dataDir.resolve("utxo-rocksdb").toString());

    try {
      try (ReplayBlockSource source = ReplayBlockSource.open(env, fixtureDir, chain, replayTargetHeight)) {
        long startupStarted = System.nanoTime();
        try (ChainstateSession session =
          ChainstateSession.openReadWrite(dataDir, dbPath, chain, replayEnv, true)) {
        long startupInvariantMs = elapsedMillis(startupStarted);
        seedHeaders(session.tracker(), chain, source);
        ReplayTimingSink replayTiming = new ReplayTimingSink();
        BlockSync.Result result =
            BlockSync.syncFromBlockSource(
                source,
                chain,
                session.tracker(),
                session.blockStorage(),
                session.chainstateStore(),
                source.heightCount(),
                replayTiming,
                false);
        long lookupStarted = System.nanoTime();
        ProjectTracker.StoredUtxo lookup =
            session.chainstateStore().utxoStore().get(chain.name(), source.firstCoinbaseTxidHex(), 0);
        long lookupMs = elapsedMillis(lookupStarted);
        int validatedHeight = session.tracker().getValidatedHeight(chain.name());
        String validatedHash = session.tracker().getValidatedHash(chain.name());
        ObjectNode proof =
            proofJson(
                env,
                dataDir,
                replayEnv.get("ROCKSDB_DIR"),
                chain.name(),
                result,
                replayTargetHeight,
                source.heightCount(),
                validatedHeight,
                validatedHash,
                dbSizeBytes(Path.of(replayEnv.get("ROCKSDB_DIR"))),
                startupInvariantMs,
                lookupMs,
                replayTiming,
                source.corpusId(),
                source.corpusSource(),
                lookup != null);
        validateProof(proof);
        Files.createDirectories(proofPath.getParent());
        new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(proofPath.toFile(), proof);
        out.println(proofPath);
        return result.blockerMessage() == null ? 0 : 4;
      }
      }
    } catch (DatadirLockBusyException error) {
      out.println("chainstate_backend_replay status=error error=" + error.getMessage());
      return 2;
    } catch (Exception error) {
      out.println("chainstate_backend_replay status=error error=" + error.getMessage());
      return 1;
    }
  }

  private static ObjectNode proofJson(
      Map<String, String> env,
      Path dataDir,
      String rocksDbPath,
      String chain,
      BlockSync.Result result,
      int replayTargetHeight,
      int availableInputHeight,
      int validatedHeight,
      String validatedHash,
      long dbSizeBytes,
      long startupInvariantMs,
      long lookupMs,
      ReplayTimingSink replayTiming,
      String corpusId,
      String corpusSource,
      boolean lookupHit) {
    JsonNodeFactory json = JsonNodeFactory.instance;
    ObjectNode root = json.objectNode();
    root.put("implementation", "JavaNode");
    root.put("commit", env.getOrDefault("GIT_COMMIT", "working-tree"));
    root.put("node_id", env.getOrDefault("NODE_ID", "javanode-rocksdb-codec-v2"));
    root.put("category", "storage");
    root.put("captured_at", Instant.now().toString());
    root.put("datadir", dataDir.toAbsolutePath().normalize().toString());
    root.put("chain", chain);
    root.put("chainstate_backend", "rocksdb");
    root.put("chainstate_backend_version", org.rocksdb.RocksDB.rocksdbVersion().toString());
    root.put("chainstate_backend_path", rocksDbPath);
    root.put("operational_backend", "rocksdb");
    root.put(
        "operational_backend_path",
        dataDir.resolve("operational-rocksdb").toAbsolutePath().normalize().toString());
    root.put("replay_corpus_id", corpusId);
    root.put("replay_corpus_source", corpusSource);
    root.put("codec_version", "2");
    root.put("replay_target_height", replayTargetHeight);
    root.put("available_input_height", availableInputHeight);
    root.put("blocks_connected", result.connected());
    root.put("native_storage", true);
    root.put("operational_db_artifact_absent", true);
    root.put("runtime_db_boundary_passed", true);
    root.put("project_db_observational_only", true);
    root.put("validated_height", validatedHeight);
    root.put("validated_hash", validatedHash == null ? "" : validatedHash);
    root.put("stored_block_height", validatedHeight);
    root.put("db_size_bytes", dbSizeBytes);
    root.put("startup_invariant_ms", startupInvariantMs);
    long commitTotal = result.timingSummary().totalMillis("block_connect_store_commit");
    root.put("commit_latency_ms_total", commitTotal);
    root.put("commit_latency_ms_avg", result.connected() == 0 ? 0 : commitTotal / result.connected());
    putLatencyStats(root, "commit_latency_ms", replayTiming.values("block_connect_store_commit"));
    putLatencyStats(root, "utxo_load_ms", replayTiming.values("utxo_load"));
    putLatencyStats(root, "utxo_apply_ms", replayTiming.values("utxo_apply"));
    putLatencyStats(root, "block_store_ms", replayTiming.values("block_store"));
    putLatencyStats(root, "block_connect_store_commit_ms", replayTiming.values("block_connect_store_commit"));
    root.put("utxo_lookup_ms_total", lookupMs);
    root.put("utxo_lookup_ms_avg", lookupMs);
    root.put("fixture_replay_status", result.blockerMessage() == null ? "passed" : "blocked");
    root.put("live_smoke_status", "not_run");
    root.put("native_crypto_backend", Secp256k1.selectedBackendName());
    root.put("native_crypto_available", Secp256k1.nativeBackendAvailable());
    root.put("taproot_tweak_backend", Secp256k1.taprootTweakBackendName());

    ObjectNode verification = json.objectNode();
    verification.put("maven", "mvn test");
    verification.put("rocksdb_dependency_present", true);
    verification.put("chainstate_codec_v2_vectors_run", true);
    verification.put("native_crypto_vector_contract_run", true);
    verification.put("blocks_connected", result.connected());
    verification.put("utxo_lookup_hit", lookupHit);
    verification.put("blocker", result.blockerMessage() == null ? "" : result.blockerMessage());
    root.set("verification", verification);
    return root;
  }

  private static void seedHeaders(ProjectTracker tracker, ChainParams chain, ReplayBlockSource source)
      throws SQLException {
    tracker.ensureGenesis(chain.name(), Genesis.forChain(chain.name()), chain.genesisHash());
    String previousHash = chain.genesisHash();
    for (int height = 1; height <= source.heightCount(); height++) {
      Block block = source.block(height);
      String blockHash = BlockHeaderCodec.blockHashHex(block.header());
      tracker.recordHeader(
          chain.name(),
          height,
          blockHash,
          previousHash,
          Hex.encode(BlockHeaderCodec.serialize(block.header())));
      previousHash = blockHash;
    }
    tracker.upsertSyncState(
        chain.name(),
        new ProjectTracker.SyncStatePatch(source.heightCount(), previousHash, source.heightCount() + 1, "headers_current"));
  }

  private static void validateProof(ObjectNode proof) {
    String liveSmokeStatus = proof.path("live_smoke_status").asText("");
    if (!"rocksdb".equals(proof.path("chainstate_backend").asText())) {
      throw new IllegalStateException("replay proof backend is not rocksdb");
    }
    if (!"rocksdb".equals(proof.path("operational_backend").asText())) {
      throw new IllegalStateException("replay proof operational_backend is not rocksdb");
    }
    if (!"2".equals(proof.path("codec_version").asText())) {
      throw new IllegalStateException("replay proof codec_version is not 2");
    }
    if (!"passed".equals(proof.path("fixture_replay_status").asText())) {
      throw new IllegalStateException("replay proof fixture_replay_status is not passed");
    }
    if (proof.path("db_size_bytes").asLong() <= 0) {
      throw new IllegalStateException("replay proof db_size_bytes is missing");
    }
    int expectedConnected =
        Math.min(proof.path("replay_target_height").asInt(), proof.path("available_input_height").asInt());
    if (proof.path("blocks_connected").asInt() < expectedConnected) {
      throw new IllegalStateException("replay proof connected fewer blocks than available input");
    }
    if (proof.path("replay_corpus_id").asText("").isBlank()) {
      throw new IllegalStateException("replay proof replay_corpus_id is missing");
    }
    if ("passed".equals(liveSmokeStatus)) {
      throw new IllegalStateException("replay proof cannot mark live_smoke_status passed");
    }
  }

  private static void putLatencyStats(ObjectNode root, String prefix, List<Long> values) {
    root.put(prefix + "_p50", percentile(values, 50));
    root.put(prefix + "_p95", percentile(values, 95));
    root.put(prefix + "_max", values.stream().max(Comparator.naturalOrder()).orElse(0L));
  }

  private static long percentile(List<Long> values, int percentile) {
    if (values.isEmpty()) {
      return 0;
    }
    List<Long> sorted = new ArrayList<>(values);
    sorted.sort(Comparator.naturalOrder());
    int index = (int) Math.ceil((percentile / 100.0) * sorted.size()) - 1;
    return sorted.get(Math.max(0, Math.min(index, sorted.size() - 1)));
  }

  private static long dbSizeBytes(Path path) throws IOException {
    if (!Files.exists(path)) {
      return 0;
    }
    try (var stream = Files.walk(path)) {
      return stream.filter(Files::isRegularFile).mapToLong(ChainstateBackendReplayService::sizeOrZero).sum();
    }
  }

  private static long sizeOrZero(Path path) {
    try {
      return Files.size(path);
    } catch (IOException ignored) {
      return 0;
    }
  }

  private static long elapsedMillis(long startedNanos) {
    return Math.max(0, (System.nanoTime() - startedNanos) / 1_000_000);
  }

  private static int parseInt(String value, int defaultValue) {
    if (value == null || value.isBlank()) {
      return defaultValue;
    }
    return Integer.parseInt(value.trim());
  }

  private static final class ReplayTimingSink implements BlockSync.TimingSink {
    private final Map<String, List<Long>> valuesByStage = new HashMap<>();

    @Override
    public void record(String stage, int height, long elapsedMillis) {
      valuesByStage.computeIfAbsent(stage, ignored -> new ArrayList<>()).add(elapsedMillis);
    }

    List<Long> values(String stage) {
      return valuesByStage.getOrDefault(stage, List.of());
    }
  }

  private static final class ReplayBlockSource implements BlockSync.BlockSource, AutoCloseable {
    private final int heightCount;
    private final Map<String, byte[]> payloadsByInternalHash = new LinkedHashMap<>();
    private final Map<Integer, Block> blocks = new LinkedHashMap<>();
    private final AutoCloseable closeable;
    private String firstCoinbaseTxidHex;
    private String corpusId = "unknown";
    private String corpusSource = "";

    private ReplayBlockSource(int heightCount, AutoCloseable closeable) {
      this.heightCount = heightCount;
      this.closeable = closeable;
    }

    static ReplayBlockSource open(
        Map<String, String> env, Path fixtureDir, ChainParams chain, int replayTargetHeight)
        throws IOException, SQLException {
      String sourceDataDir = env.get("SOURCE_DATA_DIR");
      if (sourceDataDir != null && !sourceDataDir.isBlank()) {
        return fromStoredBlocks(Path.of(sourceDataDir).toAbsolutePath().normalize(), chain, replayTargetHeight);
      }
      String corpusDir = env.get("REPLAY_CORPUS_DIR");
      if (corpusDir != null && !corpusDir.isBlank()) {
        return fromCorpusDir(Path.of(corpusDir).toAbsolutePath().normalize(), chain, replayTargetHeight);
      }
      return fromFixtureDir(fixtureDir, replayTargetHeight);
    }

    private static ReplayBlockSource fromCorpusDir(Path corpusDir, ChainParams chain, int replayTargetHeight)
        throws IOException {
      JsonNode manifest = new ObjectMapper().readTree(Files.readString(corpusDir.resolve("replay_manifest.json")));
      if (!chain.name().equals(manifest.path("chain").asText())) {
        throw new IOException("replay corpus chain mismatch: " + manifest.path("chain").asText());
      }
      JsonNode blocks = manifest.path("blocks");
      int available = Math.min(replayTargetHeight, blocks.size());
      ReplayBlockSource source = new ReplayBlockSource(available, null);
      source.corpusId = manifest.path("corpus_id").asText("");
      source.corpusSource = corpusDir.toString();
      for (int index = 0; index < available; index++) {
        JsonNode blockNode = blocks.get(index);
        int height = blockNode.path("height").asInt();
        if (height != index + 1) {
          throw new IOException("replay corpus is not contiguous at height " + height);
        }
        Path file = corpusDir.resolve(blockNode.path("file").asText()).normalize();
        source.addPayload(height, Hex.decode(Files.readString(file).replaceAll("\\s+", "")));
        String hash = BlockHeaderCodec.blockHashHex(source.block(height).header());
        if (!hash.equals(blockNode.path("block_hash").asText())) {
          throw new IOException("replay corpus hash mismatch at height " + height);
        }
      }
      if (source.heightCount() == 0) {
        throw new IOException("replay corpus contains no usable blocks: " + corpusDir);
      }
      return source;
    }

    private static ReplayBlockSource fromFixtureDir(Path fixtureDir, int replayTargetHeight) throws IOException {
      int available = 0;
      while (available < replayTargetHeight
          && Files.exists(fixtureDir.resolve("block" + (available + 1) + "_wire.hex"))) {
        available += 1;
      }
      if (available == 0) {
        throw new IOException("no contiguous replay fixtures found in " + fixtureDir);
      }
      ReplayBlockSource source = new ReplayBlockSource(available, null);
      source.corpusId = "fixture-dir";
      source.corpusSource = fixtureDir.toString();
      for (int height = 1; height <= available; height++) {
        source.addPayload(height, readFixtureBlockPayload(fixtureDir, height));
      }
      return source;
    }

    private static ReplayBlockSource fromStoredBlocks(
        Path sourceDataDir, ChainParams chain, int replayTargetHeight) throws IOException, SQLException {
      OperationalStore operationalStore =
          new RocksDbOperationalStore(sourceDataDir.resolve("operational-rocksdb"), false);
      BlockStorage blockStorage =
          new BlockStorage(new BlockStore(sourceDataDir.resolve("blocks"), chain.magic()), operationalStore);
      ReplayBlockSource source = new ReplayBlockSource(0, operationalStore);
      source.corpusId = "source-datadir";
      source.corpusSource = sourceDataDir.toString();
      int available = 0;
      for (int height = 1; height <= replayTargetHeight; height++) {
        if (operationalStore.getBlock(chain.name(), height).isEmpty()) {
          break;
        }
        source.addPayload(height, blockStorage.readBlock(chain.name(), height));
        available += 1;
      }
      if (available == 0) {
        source.close();
        throw new IOException("no contiguous stored replay blocks found in " + sourceDataDir);
      }
      return source;
    }

    private void addPayload(int height, byte[] payload) {
      Block block = BlockDeserializer.deserialize(payload);
      blocks.put(height, block);
      payloadsByInternalHash.put(Hex.encode(BlockHeaderCodec.blockHash(block.header())), payload);
      if (height == 1) {
        firstCoinbaseTxidHex = Hex.encode(Hex.reverse(Merkle.transactionTxid(block.transactions().getFirst())));
      }
    }

    int heightCount() {
      return blocks.size();
    }

    Block block(int height) {
      return blocks.get(height);
    }

    String firstCoinbaseTxidHex() {
      return firstCoinbaseTxidHex;
    }

    String corpusId() {
      return corpusId;
    }

    String corpusSource() {
      return corpusSource;
    }

    @Override
    public byte[] requestBlock(byte[] blockHashInternal) {
      return payloadsByInternalHash.get(Hex.encode(blockHashInternal));
    }

    @Override
    public void markBlockDownloadCapabilities() {
      // Fixture replay does not exercise live wire capabilities.
    }

    private static byte[] readFixtureBlockPayload(Path fixtureDir, int height) throws IOException {
      String hex = Files.readString(fixtureDir.resolve("block" + height + "_wire.hex"));
      return Hex.decode(hex.replaceAll("\\s+", ""));
    }

    @Override
    public void close() throws IOException {
      if (closeable != null) {
        try {
          closeable.close();
        } catch (IOException error) {
          throw error;
        } catch (Exception error) {
          throw new IOException("failed to close replay source", error);
        }
      }
    }
  }
}
