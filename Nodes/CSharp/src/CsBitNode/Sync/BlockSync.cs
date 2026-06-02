using CsBitNode.Chain;
using CsBitNode.Consensus.Connect;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.P2p;
using CsBitNode.Storage;
using CsBitNode.Util;

namespace CsBitNode.Sync;

public static class BlockSync
{
    public interface IBlockSource
    {
        byte[]? RequestBlock(byte[] blockHashInternal);
    }

    public static BlockSyncResult SyncFromPeer(
        PeerConnection peer,
        ChainParams chain,
        IChainstateStore tracker,
        BlockStorage blockStorage,
        int maxBlocks)
    {
        return SyncFromBlockSource(peer, chain, tracker, blockStorage, maxBlocks);
    }

    public static BlockSyncResult SyncFromBlockSource(
        IBlockSource blockSource,
        ChainParams chain,
        IChainstateStore tracker,
        BlockStorage blockStorage,
        int maxBlocks,
        ITimingSink? timingSink = null)
    {
        var downloaded = 0;
        var connected = 0;
        ValidationBlocker? blocker = null;
        string syncStatus = "blocks_syncing";

        while (maxBlocks <= 0 || connected < maxBlocks)
        {
            var nextHeight = tracker.GetValidatedHeight(chain.Name) + 1;
            var headerHashHex = tracker.GetHeaderHash(chain.Name, nextHeight)
                ?? throw new InvalidOperationException($"missing header at height {nextHeight}");

            byte[] prevInternal;
            if (nextHeight == 0)
                prevInternal = new byte[32];
            else
            {
                var prevHashHex = tracker.GetHeaderHash(chain.Name, nextHeight - 1)
                    ?? throw new InvalidOperationException($"missing prev header at {nextHeight - 1}");
                prevInternal = Hex.Reverse(Hex.Decode(prevHashHex));
            }

            var blockHashInternal = Hex.Reverse(Hex.Decode(headerHashHex));

            var payload = blockSource.RequestBlock(blockHashInternal);
            if (payload is null)
            {
                tracker.LogEvent("sync", $"peer did not return block at height {nextHeight}", "warning");
                syncStatus = "blocked";
                break;
            }

            var blockStarted = System.Diagnostics.Stopwatch.StartNew();
            downloaded += 1;
            var storeStarted = System.Diagnostics.Stopwatch.StartNew();
            var stored = blockStorage.Store(payload);
            storeStarted.Stop();
            timingSink?.Record("block_store", nextHeight, storeStarted.ElapsedMilliseconds);
            tracker.RecordBlock(chain.Name, nextHeight, headerHashHex, stored.FileNumber, stored.FileOffset, stored.BlockSize);

            try
            {
                BlockConnector.Connect(
                    tracker,
                    chain.Name,
                    nextHeight,
                    payload,
                    prevInternal,
                    blockHashInternal);
                blockStarted.Stop();
                timingSink?.Record("block_connect_store_commit", nextHeight, blockStarted.ElapsedMilliseconds);
                connected += 1;
            }
            catch (ValidationBlocker validationBlocker)
            {
                blocker = validationBlocker;
                tracker.RecordBlocker(chain.Name, validationBlocker);
                tracker.LogEvent("consensus", validationBlocker.Message, "error");
                syncStatus = "blocked";
                break;
            }
            catch (ConnectBlockException error)
            {
                tracker.LogEvent("consensus", error.Message, "error");
                syncStatus = "failed";
                break;
            }
        }

        if (blocker is null && syncStatus != "failed" && syncStatus != "blocked")
            syncStatus = connected > 0 ? "blocks_syncing" : syncStatus;

        tracker.UpsertSyncState(chain.Name, new SyncStatePatch(null, null, null, syncStatus));

        return new BlockSyncResult(downloaded, connected, syncStatus, blocker?.Message);
    }
}

public sealed record BlockSyncResult(int Downloaded, int Connected, string SyncStatus, string? BlockerMessage);

public interface ITimingSink
{
    void Record(string stage, int height, long elapsedMillis);
}
