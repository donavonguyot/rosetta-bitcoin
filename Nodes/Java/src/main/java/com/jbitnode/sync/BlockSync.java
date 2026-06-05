package com.jbitnode.sync;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.config.ScriptVerifySettings;
import com.jbitnode.consensus.connect.BlockConnector;
import com.jbitnode.consensus.connect.ConnectBlockException;
import com.jbitnode.consensus.connect.ValidationBlocker;
import com.jbitnode.consensus.script.ScriptVerifyRunner;
import com.jbitnode.db.ChainstateStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.ProjectTracker.SyncStatePatch;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.util.Hex;
import java.io.IOException;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** Downloads raw blocks and connects heights with script verification. */
public final class BlockSync {

  public static final int DEFAULT_BATCH_SIZE = 32;

  /** Default number of blocks the background prefetcher may stay ahead of the connect loop. */
  static final int DEFAULT_PREFETCH_DEPTH = 4;

  /** Upper bound for take() so a silent/dead peer becomes an "unavailable" blocker, not a hang. */
  private static final long PREFETCH_TAKE_TIMEOUT_MS = 300_000;

  private BlockSync() {}

  private static int prefetchDepthFromEnv() {
    String raw = System.getenv("BLOCK_PREFETCH_DEPTH");
    if (raw == null || raw.isBlank()) {
      return DEFAULT_PREFETCH_DEPTH;
    }
    try {
      return Math.max(1, Math.min(64, Integer.parseInt(raw.trim())));
    } catch (NumberFormatException ignored) {
      return DEFAULT_PREFETCH_DEPTH;
    }
  }

  // The per-block "Block connected" event is an operational-store write per height. During bulk
  // catch-up it is pure overhead (progress is tracked by validated height + timing summary), so it
  // is off by default and re-enabled with SYNC_LOG_CONNECTED_BLOCKS=1 for verbose observation.
  private static boolean logConnectedBlocksFromEnv() {
    String raw = System.getenv("SYNC_LOG_CONNECTED_BLOCKS");
    if (raw == null) {
      return false;
    }
    String trimmed = raw.trim();
    return trimmed.equals("1")
        || trimmed.equalsIgnoreCase("true")
        || trimmed.equalsIgnoreCase("yes");
  }

  public record Result(
      int downloaded,
      int connected,
      int validatedHeight,
      String syncStatus,
      String blockerMessage,
      TimingSummary timingSummary) {}

  public record TimingSummary(
      int connectedBlocks, Map<String, Long> totalMillisByStage, List<SlowBlock> slowBlocks) {
    public long totalMillis(String stage) {
      return totalMillisByStage.getOrDefault(stage, 0L);
    }

    public long averageMillis(String stage) {
      return connectedBlocks == 0 ? 0 : totalMillis(stage) / connectedBlocks;
    }
  }

  public record SlowBlock(
      int height,
      int blockSize,
      int inputCount,
      int txCount,
      int vinCount,
      int voutCount,
      int scriptInputCount,
      Map<String, Integer> inputShapeCounts,
      Map<String, Integer> spentPrevoutScriptTypes,
      Map<String, Integer> outputScriptTypes,
      long utxoLoadMillis,
      long scriptVerifyMillis,
      long utxoApplyMillis,
      long commitMillis,
      long blockConnectStoreCommitMillis) {}

  @FunctionalInterface
  public interface TimingSink {
    void record(String stage, int height, long elapsedMillis) throws SQLException;

    static TimingSink none() {
      return (stage, height, elapsedMillis) -> {};
    }
  }

  public interface BlockSource {
    byte[] requestBlock(byte[] blockHashInternal) throws IOException;

    void markBlockDownloadCapabilities() throws SQLException;
  }

  public static Result syncFromPeer(
      PeerConnection peer,
      ChainParams chain,
      ProjectTracker tracker,
      BlockStorage blockStorage,
      ChainstateStore chainstateStore,
      int maxBlocks,
      TimingSink timingSink,
      boolean replaceBlockMetadata)
      throws IOException, SQLException {
    return syncFromBlockSource(
        new BlockSource() {
          @Override
          public byte[] requestBlock(byte[] blockHashInternal) throws IOException {
            return peer.requestBlock(blockHashInternal);
          }

          @Override
          public void markBlockDownloadCapabilities() throws SQLException {
            peer.markBlockDownloadCapabilities();
          }
        },
        chain,
        tracker,
        blockStorage,
        chainstateStore,
        maxBlocks,
        timingSink,
        replaceBlockMetadata);
  }

  public static Result syncFromBlockSource(
      BlockSource blockSource,
      ChainParams chain,
      ProjectTracker tracker,
      BlockStorage blockStorage,
      ChainstateStore chainstateStore,
      int maxBlocks,
      TimingSink timingSink,
      boolean replaceBlockMetadata)
      throws IOException, SQLException {
    tracker.upsertSyncState(chain.name(), new SyncStatePatch(null, null, null, "blocks_syncing"));
    TimingCollector timingCollector = new TimingCollector(timingSink);

    int downloaded = 0;
    int connected = 0;
    String blockerMessage = null;
    boolean chunkLimitReached = false;
    int prefetchDepth = prefetchDepthFromEnv();
    boolean logConnectedBlocks = logConnectedBlocksFromEnv();

    // Wire-capability puts are idempotent timestamped writes; recording them once per run (instead
    // of once per connected block) removes a steady stream of redundant operational-store writes
    // from the hot loop without losing the capability signal.
    boolean downloadCapsMarked = false;
    boolean blockStoreCapMarked = false;

    // One runner (worker pool + warm secp256k1 verification cache) for the whole batch, instead of
    // constructing and tearing down a thread pool on every connected block.
    try (ScriptVerifyRunner scriptVerifyRunner =
        new ScriptVerifyRunner(ScriptVerifySettings.fromEnv())) {
    while (maxBlocks <= 0 || downloaded < maxBlocks) {
      int batchLimit = maxBlocks > 0 ? Math.min(DEFAULT_BATCH_SIZE, maxBlocks - downloaded) : DEFAULT_BATCH_SIZE;
      List<Integer> missing = tracker.listMissingBlockHeights(chain.name(), batchLimit);
      if (missing.isEmpty()) {
        markBlocksCurrent(chain, tracker);
        return new Result(
            downloaded,
            connected,
            tracker.getValidatedHeight(chain.name()),
            "blocks_current",
            null,
            timingCollector.summary());
      }

      // Plan the download for the contiguous prefix of the batch that has headers. The background
      // prefetcher streams these block payloads in order while this thread connects earlier blocks,
      // overlapping network transfer with script verification. Heights without a header stop the
      // plan; the connect loop below independently surfaces the same missing-header blocker.
      List<BlockPrefetcher.Plan> plan = new ArrayList<>(missing.size());
      for (int height : missing) {
        String planHashHex = tracker.getHeaderHash(chain.name(), height);
        if (planHashHex == null) {
          break;
        }
        plan.add(new BlockPrefetcher.Plan(height, Hex.reverse(Hex.decode(planHashHex))));
      }

      try (BlockPrefetcher prefetcher =
          new BlockPrefetcher(blockSource::requestBlock, plan, prefetchDepth)) {
      for (int height : missing) {
        if (maxBlocks > 0 && downloaded >= maxBlocks) {
          break;
        }
        int nextConnectHeight = tracker.getValidatedHeight(chain.name()) + 1;
        if (height != nextConnectHeight) {
          blockerMessage =
              ChainConsistency.blockStorageGapMessage(nextConnectHeight, height);
          break;
        }
        Optional<byte[]> expectedPrev = expectedPrevHash(tracker, chain.name(), height);
        if (expectedPrev.isEmpty()) {
          blockerMessage = "missing header at height " + (height - 1);
          break;
        }
        String blockHashHex = tracker.getHeaderHash(chain.name(), height);
        if (blockHashHex == null) {
          blockerMessage = "missing header at height " + height;
          break;
        }
        byte[] blockHashInternal = Hex.reverse(Hex.decode(blockHashHex));

        long downloadStarted = System.nanoTime();
        BlockPrefetcher.Fetched fetched;
        try {
          fetched = prefetcher.take(PREFETCH_TAKE_TIMEOUT_MS);
        } catch (InterruptedException interrupted) {
          Thread.currentThread().interrupt();
          throw new IOException(
              "interrupted waiting for prefetched block at height " + height, interrupted);
        }
        timingSink.record("block_download_wait", height, elapsedMillis(downloadStarted));
        byte[] payload = fetched == null ? null : fetched.payload();
        if (payload == null || fetched.height() != height) {
          tracker.markWireCapability(
              "blocks.notfound", true, "live", "peer returned notfound for block");
          tracker.logEvent(
              "sync",
              "Block unavailable from peer",
              "warning",
              "{\"height\":" + height + ",\"block_hash\":\"" + blockHashHex + "\"}");
          blockerMessage = "block unavailable at height " + height;
          break;
        }

        try {
          BlockConnector.ConnectResult result =
              connectAndStoreBlock(
                  tracker,
                  chain.name(),
                  height,
                  payload,
                  expectedPrev.get(),
                  blockHashInternal,
                  blockStorage,
                  chainstateStore,
                  replaceBlockMetadata,
                  timingCollector,
                  scriptVerifyRunner,
                  logConnectedBlocks);
          timingCollector.recordBlock(
              height,
              payload.length,
              result.inputCount(),
              result.shapeSummary());
          if (!downloadCapsMarked) {
            blockSource.markBlockDownloadCapabilities();
            downloadCapsMarked = true;
          }
          if (!blockStoreCapMarked) {
            tracker.markWireCapability(
                "blocks.block.store",
                true,
                "live",
                "stored block height " + height);
            blockStoreCapMarked = true;
          }
          connected += 1;
          downloaded += 1;
        } catch (ValidationBlocker blocker) {
          tracker.logEvent(
              "sync",
              "Block connect stopped at validation blocker",
              "warning",
              blockerEventJson(blocker));
          blockerMessage = blocker.getMessage();
          tracker.upsertSyncState(
              chain.name(), new SyncStatePatch(null, null, null, "blocks_blocked"));
          return new Result(
              downloaded,
              connected,
              tracker.getValidatedHeight(chain.name()),
              "blocks_blocked",
              blockerMessage,
              timingCollector.summary());
        } catch (ConnectBlockException error) {
          tracker.logEvent(
              "sync",
              "Block connect stopped",
              "warning",
              "{\"height\":"
                  + height
                  + ",\"error\":\""
                  + error.getMessage().replace("\"", "'")
                  + "\"}");
          blockerMessage = error.getMessage();
          return new Result(
              downloaded,
              connected,
              tracker.getValidatedHeight(chain.name()),
              "blocks_blocked",
              blockerMessage,
              timingCollector.summary());
        }
      }
      }

      if (blockerMessage != null) {
        break;
      }
      if (maxBlocks > 0 && downloaded >= maxBlocks) {
        chunkLimitReached = true;
        break;
      }
    }
    }

    if (blockerMessage != null) {
      return new Result(
          downloaded,
          connected,
          tracker.getValidatedHeight(chain.name()),
          "blocks_blocked",
          blockerMessage,
          timingCollector.summary());
    }

    String status;
    if (tracker.listMissingBlockHeights(chain.name(), 1).isEmpty()) {
      status = "blocks_current";
    } else if (chunkLimitReached && maxBlocks > 0) {
      status = "blocks_idle";
    } else {
      status = "blocks_syncing";
    }
    tracker.upsertSyncState(chain.name(), new SyncStatePatch(null, null, null, status));
    return new Result(
        downloaded,
        connected,
        tracker.getValidatedHeight(chain.name()),
        status,
        blockerMessage,
        timingCollector.summary());
  }

  static Optional<byte[]> expectedPrevHash(ProjectTracker tracker, String chain, int height)
      throws SQLException {
    if (height < 1) {
      return Optional.empty();
    }
    String prevHex = tracker.getHeaderHash(chain, height - 1);
    if (prevHex == null) {
      return Optional.empty();
    }
    return Optional.of(Hex.reverse(Hex.decode(prevHex)));
  }

  static BlockConnector.ConnectResult connectAndStoreBlock(
      ProjectTracker tracker,
      String chain,
      int height,
      byte[] payload,
      byte[] expectedPrev,
      byte[] expectedHash,
      BlockStorage blockStorage,
      ChainstateStore chainstateStore,
      boolean replaceBlockMetadata,
      TimingSink timingSink,
      ScriptVerifyRunner scriptVerifyRunner,
      boolean logConnectedBlock)
      throws SQLException, ConnectBlockException, ValidationBlocker {
    long started = System.nanoTime();
    BlockConnector.ConnectResult result =
        BlockConnector.connectInCurrentTransaction(
            tracker,
            chainstateStore,
            chain,
            height,
            payload,
            expectedPrev,
            expectedHash,
            (stage, timedHeight, elapsedMillis) ->
                timingSink.record(stage, timedHeight, elapsedMillis),
            scriptVerifyRunner);
    long blockStoreStarted = System.nanoTime();
    if (replaceBlockMetadata) {
      blockStorage.storeBlockReplacingMetadata(chain, height, result.blockHashHex(), payload);
    } else {
      blockStorage.storeBlock(chain, height, result.blockHashHex(), payload);
    }
    timingSink.record("block_store", height, elapsedMillis(blockStoreStarted));
    timingSink.record("block_connect_store_commit", height, elapsedMillis(started));
    if (logConnectedBlock) {
      tracker.logEvent(
          "sync",
          "Block connected",
          "info",
          "{\"height\":"
              + height
              + ",\"block_hash\":\""
              + result.blockHashHex()
              + "\",\"utxos_created\":"
              + result.utxosCreated()
              + "}");
    }
    return result;
  }

  static long elapsedMillis(long startedNanos) {
    return Math.max(0, (System.nanoTime() - startedNanos) / 1_000_000);
  }

  private static final class TimingCollector implements TimingSink {
    private final TimingSink delegate;
    private final Map<Integer, Map<String, Long>> blockStageMillis = new HashMap<>();
    private final Map<Integer, BlockShape> blockShapes = new HashMap<>();
    private final Map<String, Long> totalMillisByStage = new HashMap<>();

    TimingCollector(TimingSink delegate) {
      this.delegate = delegate;
    }

    @Override
    public void record(String stage, int height, long elapsedMillis) throws SQLException {
      delegate.record(stage, height, elapsedMillis);
      blockStageMillis.computeIfAbsent(height, ignored -> new HashMap<>()).put(stage, elapsedMillis);
      totalMillisByStage.merge(stage, elapsedMillis, Long::sum);
    }

    void recordBlock(
        int height,
        int blockSize,
        int inputCount,
        BlockConnector.BlockShapeSummary shapeSummary) {
      blockShapes.put(height, new BlockShape(blockSize, inputCount, shapeSummary));
    }

    TimingSummary summary() {
      List<SlowBlock> slowBlocks = new ArrayList<>();
      for (Map.Entry<Integer, BlockShape> entry : blockShapes.entrySet()) {
        Map<String, Long> stages = blockStageMillis.getOrDefault(entry.getKey(), Map.of());
        slowBlocks.add(
            new SlowBlock(
                entry.getKey(),
                entry.getValue().blockSize(),
                entry.getValue().inputCount(),
                entry.getValue().shapeSummary().txCount(),
                entry.getValue().shapeSummary().vinCount(),
                entry.getValue().shapeSummary().voutCount(),
                entry.getValue().shapeSummary().scriptInputCount(),
                entry.getValue().shapeSummary().inputShapeCounts(),
                entry.getValue().shapeSummary().spentPrevoutScriptTypes(),
                entry.getValue().shapeSummary().outputScriptTypes(),
                stages.getOrDefault("utxo_load", 0L),
                stages.getOrDefault("script_verify", 0L),
                stages.getOrDefault("utxo_apply", 0L),
                stages.getOrDefault("commit", 0L),
                stages.getOrDefault("block_connect_store_commit", 0L)));
      }
      slowBlocks.sort(
          Comparator.comparingLong(SlowBlock::blockConnectStoreCommitMillis).reversed()
              .thenComparingInt(SlowBlock::height));
      if (slowBlocks.size() > 10) {
        slowBlocks = new ArrayList<>(slowBlocks.subList(0, 10));
      }
      return new TimingSummary(blockShapes.size(), Map.copyOf(totalMillisByStage), List.copyOf(slowBlocks));
    }
  }

  private record BlockShape(
      int blockSize, int inputCount, BlockConnector.BlockShapeSummary shapeSummary) {}

  static String blockerEventJson(ValidationBlocker blocker) {
    return "{"
        + "\"height\":"
        + blocker.height()
        + ",\"block_hash\":\""
        + blocker.blockHashHex()
        + "\",\"txid\":\""
        + blocker.txidHex()
        + "\",\"input_index\":"
        + blocker.inputIndex()
        + ",\"spent_script_pubkey\":\""
        + blocker.spentScriptPubKeyHex()
        + "\",\"missing_rule\":\""
        + blocker.missingRule().replace("\"", "'")
        + "\",\"failure\":\""
        + blocker.getMessage().replace("\"", "'")
        + "\"}";
  }

  static void markBlocksCurrent(ChainParams chain, ProjectTracker tracker) throws SQLException {
    tracker.upsertSyncState(
        chain.name(), new SyncStatePatch(null, null, null, "blocks_current"));
    tracker.markWireCapability(
        "blocks.sync_to_tip", true, "live", "downloaded blocks through header tip");
  }
}
