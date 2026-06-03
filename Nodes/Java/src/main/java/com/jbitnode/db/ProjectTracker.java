package com.jbitnode.db;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.util.Hex;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/** Runtime node state facade backed only by JavaNode's operational store. */
public final class ProjectTracker implements AutoCloseable {

  @FunctionalInterface
  public interface UndoTimingSink {
    void record(String stage, long elapsedNanos);

    static UndoTimingSink none() {
      return (stage, elapsedNanos) -> {};
    }
  }

  private final OperationalStore operationalStore;

  public ProjectTracker(OperationalStore operationalStore) {
    if (operationalStore == null) {
      throw new IllegalArgumentException("ProjectTracker requires an OperationalStore");
    }
    this.operationalStore = operationalStore;
  }

  public int getValidatedHeight(String chain) throws SQLException {
    return operationalStore.getValidatedTip(chain).height();
  }

  public String getValidatedHash(String chain) throws SQLException {
    String hash = operationalStore.getValidatedTip(chain).hash();
    return hash == null || hash.isBlank() ? null : hash;
  }

  public String getMeta(String key) throws SQLException {
    return operationalStore.getMeta(key);
  }

  public void setMeta(String key, String value) throws SQLException {
    operationalStore.setMeta(key, value);
  }

  public void setValidatedTip(String chain, int height, String blockHashHex) throws SQLException {
    operationalStore.setValidatedTip(chain, height, blockHashHex);
  }

  public int blockCount(String chain) throws SQLException {
    return operationalStore.blockCount(chain);
  }

  public boolean hasBlock(String chain, int height) throws SQLException {
    return operationalStore.getBlock(chain, height).isPresent();
  }

  public int maxStoredBlockHeight(String chain) throws SQLException {
    int max = 0;
    for (int height = 1; height <= headerCount(); height++) {
      if (operationalStore.getBlock(chain, height).isPresent()) {
        max = height;
      }
    }
    return max;
  }

  public int countBlockStorageGaps(String chain, int throughHeight) throws SQLException {
    int gaps = 0;
    for (int height = 1; height <= throughHeight; height++) {
      if (operationalStore.getHeader(chain, height).isPresent()
          && operationalStore.getBlock(chain, height).isEmpty()) {
        gaps += 1;
      }
    }
    return gaps;
  }

  public List<Integer> listMissingBlockHeights(String chain, int limit) throws SQLException {
    List<Integer> heights = new ArrayList<>();
    int headerCount = operationalStore.headerCount(chain);
    // Forward-sync hot path: blocks are stored only when connected, so nothing at or below the
    // validated tip is ever missing. Start the scan at the validated tip + 1 instead of genesis to
    // avoid an O(validated_height) RocksDB point-lookup rescan on every download batch (this was
    // near-quadratic as the chain approached tip). Historical gap detection/repair still uses
    // countBlockStorageGaps / maxStoredBlockHeight, which deliberately scan from genesis.
    int start = Math.max(1, getValidatedHeight(chain) + 1);
    for (int height = start; height < headerCount && heights.size() < limit; height++) {
      if (operationalStore.getBlock(chain, height).isEmpty()) {
        heights.add(height);
      }
    }
    return heights;
  }

  public void resetDerivedChainstate(String chain, String genesisHash) throws SQLException {
    setValidatedTip(chain, 0, genesisHash);
    upsertSyncState(chain, new SyncStatePatch(null, null, null, "chainstate_rebuilding"));
  }

  @Override
  public void close() {}

  /** Advertised start_height: validated tip, never header tip during initial sync. */
  public int bootstrapStartHeight(String chain) throws SQLException {
    return Math.max(getValidatedHeight(chain), 0);
  }

  public Optional<SyncState> getSyncState(String chain) throws SQLException {
    return operationalStore.getSyncState(chain);
  }

  public void upsertSyncState(String chain, SyncStatePatch patch) throws SQLException {
    operationalStore.upsertSyncState(chain, patch);
  }

  public int headerCount() throws SQLException {
    return operationalStore.headerCount(com.jbitnode.config.NodePaths.DEFAULT_CHAIN);
  }

  public String getHeaderHash(String chain, int height) throws SQLException {
    return operationalStore.getHeaderHash(chain, height);
  }

  public String getHeaderSerializedHex(String chain, int height) throws SQLException {
    return operationalStore
        .getHeader(chain, height)
        .map(OperationalStore.HeaderRecord::headerSerializedHex)
        .orElse(null);
  }

  public void recordHeader(
      String chain, int height, String blockHash, String prevHash, String headerSerializedHex)
      throws SQLException {
    operationalStore.recordHeader(
        new OperationalStore.HeaderRecord(chain, height, blockHash, prevHash, headerSerializedHex));
  }

  public long recordPeerConnected(
      String host,
      int port,
      String direction,
      long services,
      int peerVersion,
      String userAgent,
      int startHeight)
      throws SQLException {
    return operationalStore.logEvent(
        "p2p",
        "Peer connected",
        "info",
        "{\"host\":\"" + host + "\",\"port\":" + port + ",\"direction\":\"" + direction + "\"}");
  }

  public void recordPeerDisconnected(long peerId) throws SQLException {
    operationalStore.logEvent("p2p", "Peer disconnected", "info", "{\"peer_id\":" + peerId + "}");
  }

  public void markWireCapability(String capabilityId, boolean implemented, String verifiedBy, String notes)
      throws SQLException {
    setMeta(
        "wire." + capabilityId,
        (implemented ? "1" : "0") + "|" + verifiedBy + "|" + notes + "|" + nowIso());
  }

  public void logEvent(String source, String message, String level, String detailsJson)
      throws SQLException {
    operationalStore.logEvent(source, message, level, detailsJson);
  }

  public BlockHeader ensureGenesis(String chain, BlockHeader genesis, String genesisHash)
      throws SQLException {
    String existing = getHeaderHash(chain, 0);
    if (existing != null) {
      if (!existing.equals(genesisHash)) {
        throw new IllegalStateException(
            "Stored genesis hash " + existing + " does not match chain genesis " + genesisHash);
      }
      if (getValidatedHash(chain) == null) {
        setValidatedTip(chain, 0, genesisHash);
      }
      markWireCapability("headers.genesis", true, "code", "genesis header present");
      return genesis;
    }
    recordHeader(
        chain,
        0,
        genesisHash,
        Hex.encode(new byte[32]),
        Hex.encode(BlockHeaderCodec.serialize(genesis)));
    upsertSyncState(chain, new SyncStatePatch(0, genesisHash, 1, "genesis_seeded"));
    setValidatedTip(chain, 0, genesisHash);
    logEvent("sync", "Genesis header seeded", "info", "{\"hash\":\"" + genesisHash + "\"}");
    markWireCapability("headers.genesis", true, "code", "genesis header seeded");
    return genesis;
  }

  public List<Integer> locatorHeights(int tip) {
    List<Integer> heights = new ArrayList<>();
    int cursor = tip;
    int step = 1;
    heights.add(tip);
    while (cursor > 0) {
      cursor = Math.max(cursor - step, 0);
      heights.add(cursor);
      step <<= 1;
    }
    return heights;
  }

  public List<byte[]> nextLocator(String chain, int bestHeight, byte[] genesisHashInternal)
      throws SQLException {
    List<byte[]> hashes = new ArrayList<>();
    for (int height : locatorHeights(bestHeight)) {
      String blockHash = getHeaderHash(chain, height);
      if (blockHash != null) {
        hashes.add(Hex.reverse(Hex.decode(blockHash)));
      }
    }
    if (hashes.isEmpty()) {
      hashes.add(genesisHashInternal);
    }
    markWireCapability("headers.locator", true, "code", "locator built from height " + bestHeight);
    return hashes;
  }

  private static String nowIso() {
    return Instant.now().toString();
  }

  public record SyncState(
      String chain,
      int bestHeight,
      String bestHash,
      int headerCount,
      String syncStatus,
      String updatedAt) {}

  public record SyncStatePatch(Integer bestHeight, String bestHash, Integer headerCount, String syncStatus) {}

  public record UtxoOutpoint(String txidHex, int vout) {}

  // txid and scriptPubKey are raw bytes (txid in display/big-endian order, matching the on-disk v2
  // key layout) so the hot connect path never round-trips through hex strings. The persisted codec
  // is byte-identical: v2 already stored these as raw bytes.
  public record StoredUtxo(
      byte[] txid,
      int vout,
      int height,
      long valueSats,
      byte[] scriptPubKey,
      boolean coinbase) {}

  public record UtxoUndoEntry(
      byte[] txid, int vout, int height, long valueSats, byte[] scriptPubKey, boolean coinbase) {}
}
