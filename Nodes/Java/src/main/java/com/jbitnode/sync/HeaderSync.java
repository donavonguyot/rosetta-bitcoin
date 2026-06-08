package com.jbitnode.sync;

import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.Genesis;
import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.HeaderValidationException;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.ProjectTracker.SyncStatePatch;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.messages.HeadersMessage;
import com.jbitnode.p2p.PeerConnection;
import com.jbitnode.util.Hex;
import java.io.IOException;
import java.math.BigInteger;
import java.sql.SQLException;
import java.util.List;

/** Downloads and validates headers from a peer, persisting to SQLite. */
public final class HeaderSync {

  public static final int NEAR_PEER_TIP = 2;
  /** Default per-run header budget for routine sync batches. */
  public static final int DEFAULT_MAX_HEADERS = 2000;
  /** Extended catch-up budget (e.g. past testnet4 height 6975 from ~500). */
  public static final int EXTENDED_MAX_HEADERS = 10000;
  /** Default max getheaders round-trips per run. */
  public static final int DEFAULT_HEADER_BATCHES_MAX = 50;

  private HeaderSync() {}

  public record Result(int storedTotal, int bestHeight, String syncStatus) {}

  public static Result syncFromPeer(
      PeerConnection peer,
      ChainParams chain,
      ProjectTracker tracker,
      int maxHeaders,
      int maxBatches)
      throws IOException, SQLException {
    return syncFromPeer(peer, chain, tracker, maxHeaders, maxBatches, 0);
  }

  public static Result syncFromPeer(
      PeerConnection peer,
      ChainParams chain,
      ProjectTracker tracker,
      int maxHeaders,
      int maxBatches,
      int targetHeight)
      throws IOException, SQLException {
    BlockHeader genesis = Genesis.forChain(chain.name());
    String genesisHash = chain.genesisHash();
    tracker.ensureGenesis(chain.name(), genesis, genesisHash);
    byte[] genesisHashInternal = BlockHeaderCodec.blockHash(genesis);

    int peerHeight =
        peer.remoteVersion() != null ? peer.remoteVersion().startHeight() : -1;
    int totalStored = 0;
    int batches = 0;

    while (batches < maxBatches && totalStored < maxHeaders) {
      ProjectTracker.SyncState state =
          tracker.getSyncState(chain.name()).orElse(null);
      int bestHeight = state != null ? state.bestHeight() : 0;
      if (shouldSkip(peerHeight, bestHeight, targetHeight)) {
        markHeadersCurrent(chain, tracker);
        return new Result(totalStored, bestHeight, "headers_current");
      }

      List<byte[]> locator =
          tracker.nextLocator(chain.name(), bestHeight, genesisHashInternal);
      HeadersMessage.Message message = peer.requestHeaders(locator);
      int remainingBudget = maxHeaders - totalStored;
      if (remainingBudget <= 0) {
        break;
      }
      if (message.headers().size() > remainingBudget) {
        message =
            new HeadersMessage.Message(message.headers().subList(0, remainingBudget));
      }
      if (message.headers().isEmpty()) {
        if (targetHeight > 0 && bestHeight < targetHeight) {
          tracker.upsertSyncState(
              chain.name(), new SyncStatePatch(null, null, null, "headers_syncing"));
        } else {
          markHeadersCurrent(chain, tracker);
        }
        break;
      }

      int stored = persistHeaders(chain, tracker, message, genesisHashInternal);
      totalStored += stored;
      batches += 1;
      int currentBestHeight =
          tracker.getSyncState(chain.name()).map(ProjectTracker.SyncState::bestHeight).orElse(bestHeight);

      if (stored == 0 || headersSyncDone(currentBestHeight, peerHeight, message.headers().size(), targetHeight)) {
        if (targetHeight > 0 && currentBestHeight < targetHeight) {
          tracker.upsertSyncState(
              chain.name(), new SyncStatePatch(null, null, null, "headers_syncing"));
        } else {
          markHeadersCurrent(chain, tracker);
        }
        break;
      }
      if (totalStored >= maxHeaders) {
        tracker.upsertSyncState(
            chain.name(),
            new SyncStatePatch(null, null, tracker.headerCount(), "headers_syncing"));
        break;
      }
    }

    ProjectTracker.SyncState finalState =
        tracker.getSyncState(chain.name()).orElse(null);
    int tip = finalState != null ? finalState.bestHeight() : 0;
    String status = finalState != null ? finalState.syncStatus() : "starting";
    return new Result(totalStored, tip, status);
  }

  static boolean shouldSkip(int peerHeight, int localHeight) {
    return shouldSkip(peerHeight, localHeight, 0);
  }

  static boolean shouldSkip(int peerHeight, int localHeight, int targetHeight) {
    return peerHeight >= 0
        && localHeight >= peerHeight - NEAR_PEER_TIP
        && (targetHeight <= 0 || localHeight >= targetHeight);
  }

  static boolean headersSyncDone(int bestHeight, int peerHeight, int batchCount) {
    return headersSyncDone(bestHeight, peerHeight, batchCount, 0);
  }

  static boolean headersSyncDone(int bestHeight, int peerHeight, int batchCount, int targetHeight) {
    if (batchCount == 0) {
      return true;
    }
    if (targetHeight > 0) {
      return bestHeight >= targetHeight;
    }
    return peerHeight >= 0 && bestHeight >= peerHeight;
  }

  static int persistHeaders(
      ChainParams chain,
      ProjectTracker tracker,
      HeadersMessage.Message message,
      byte[] genesisHashInternal)
      throws SQLException {
    ProjectTracker.SyncState state =
        tracker.getSyncState(chain.name()).orElse(null);
    int tipHeight = state != null ? state.bestHeight() : 0;
    String tipHashHex =
        tracker.getHeaderHash(chain.name(), tipHeight) != null
            ? tracker.getHeaderHash(chain.name(), tipHeight)
            : chain.genesisHash();
    byte[] tipInternal =
        tipHeight == 0
            ? genesisHashInternal
            : Hex.reverse(Hex.decode(tipHashHex));

    BigInteger chainWork =
        tipHeight == 0
            ? HeaderValidator.chainWorkForHeader(Genesis.forChain(chain.name()))
            : chainWorkThroughHeight(chain, tracker, tipHeight);

    int stored = 0;
    for (BlockHeader header : message.headers()) {
      try {
        HeaderValidator.validateHeader(header, tipInternal, chainWork);
        tracker.markWireCapability("headers.pow", true, "code", "header PoW validated");
        tracker.markWireCapability("headers.chain_link", true, "code", "header chain link validated");
      } catch (HeaderValidationException e) {
        tracker.logEvent(
            "sync",
            "Header rejected at height " + (tipHeight + 1) + ": " + e.getMessage(),
            "warning",
            null);
        break;
      }

      tipHeight += 1;
      chainWork = chainWork.add(HeaderValidator.chainWorkForHeader(header));
      String blockHash = BlockHeaderCodec.blockHashHex(header);
      String prevHash = Hex.encode(Hex.reverse(header.prevBlock()));
      tracker.recordHeader(
          chain.name(),
          tipHeight,
          blockHash,
          prevHash,
          Hex.encode(BlockHeaderCodec.serialize(header)));
      tipInternal = BlockHeaderCodec.blockHash(header);
      stored += 1;
    }

    if (stored > 0) {
      String bestHash = tracker.getHeaderHash(chain.name(), tipHeight);
      tracker.upsertSyncState(
          chain.name(),
          new SyncStatePatch(tipHeight, bestHash, tracker.headerCount(), "headers_syncing"));
      tracker.markWireCapability(
          "headers.persist",
          true,
          stored > 0 ? "live" : "code",
          "stored " + stored + " headers");
    }
    return stored;
  }

  static BigInteger chainWorkThroughHeight(
      ChainParams chain, ProjectTracker tracker, int height) throws SQLException {
    BigInteger work = BigInteger.ZERO;
    for (int h = 0; h <= height; h++) {
      String hash = tracker.getHeaderHash(chain.name(), h);
      if (hash == null) {
        break;
      }
      BlockHeader header = headerAtHeight(chain, tracker, h);
      work = work.add(HeaderValidator.chainWorkForHeader(header));
    }
    return work;
  }

  static BlockHeader headerAtHeight(ChainParams chain, ProjectTracker tracker, int height)
      throws SQLException {
    if (height == 0) {
      return Genesis.forChain(chain.name());
    }
    String headerSerializedHex = tracker.getHeaderSerializedHex(chain.name(), height);
    if (headerSerializedHex == null) {
      throw new IllegalStateException("Missing header at height " + height);
    }
    return BlockHeaderCodec.deserialize(Hex.decode(headerSerializedHex), 0);
  }

  static void markHeadersCurrent(ChainParams chain, ProjectTracker tracker) throws SQLException {
    ProjectTracker.SyncState state = tracker.getSyncState(chain.name()).orElse(null);
    tracker.upsertSyncState(
        chain.name(),
        new SyncStatePatch(
            state != null ? state.bestHeight() : 0,
            state != null ? state.bestHash() : chain.genesisHash(),
            tracker.headerCount(),
            "headers_current"));
    tracker.markWireCapability(
        "headers.sync_to_tip", true, "live", "header chain at network tip");
    tracker.markWireCapability(
        "headers.resume", true, "code", "resume header sync from SQLite");
  }
}
