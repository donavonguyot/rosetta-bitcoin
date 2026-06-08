using System.Numerics;
using CsBitNode.Chain;
using CsBitNode.Consensus;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.P2p;
using CsBitNode.Util;

namespace CsBitNode.Sync;

public static class HeaderSync
{
    public const int NearPeerTip = 2;
    public const int DefaultMaxHeaders = 2000;
    public const int DefaultHeaderBatchesMax = 50;

    public sealed record Result(int StoredTotal, int BestHeight, string SyncStatus);

    public static Result SyncFromPeer(
        PeerConnection peer,
        ChainParams chain,
        IChainstateStore tracker,
        int maxHeaders,
        int maxBatches,
        int targetHeight = 0)
    {
        var genesis = Genesis.ForChain(chain.Name);
        var genesisHash = chain.GenesisHash;
        tracker.EnsureGenesis(chain.Name, genesis, genesisHash);
        var genesisHashInternal = BlockHeaderCodec.BlockHash(genesis);

        var peerHeight = peer.RemoteVersion?.StartHeight ?? -1;
        var totalStored = 0;
        var batches = 0;

        while (batches < maxBatches && totalStored < maxHeaders)
        {
            var state = tracker.GetSyncState(chain.Name);
            var bestHeight = state?.BestHeight ?? 0;
            if (ShouldSkip(peerHeight, bestHeight, targetHeight))
            {
                MarkHeadersCurrent(chain, tracker);
                return new Result(totalStored, bestHeight, "headers_current");
            }

            var locator = tracker.NextLocator(chain.Name, bestHeight, genesisHashInternal);
            var message = peer.RequestHeaders(locator);
            var remainingBudget = maxHeaders - totalStored;
            if (remainingBudget <= 0)
                break;

            var headers = message.Headers.Count > remainingBudget
                ? message.Headers.Take(remainingBudget).ToList()
                : message.Headers.ToList();

            if (headers.Count == 0)
            {
                if (targetHeight > 0 && bestHeight < targetHeight)
                    tracker.UpsertSyncState(chain.Name, new SyncStatePatch(null, null, null, "headers_syncing"));
                else
                    MarkHeadersCurrent(chain, tracker);
                break;
            }

            var stored = PersistHeaders(chain, tracker, headers, genesisHashInternal);
            totalStored += stored;
            batches += 1;
            var currentBestHeight = tracker.GetSyncState(chain.Name)?.BestHeight ?? bestHeight;

            if (stored == 0 || HeadersSyncDone(currentBestHeight, peerHeight, headers.Count, targetHeight))
            {
                if (targetHeight > 0 && currentBestHeight < targetHeight)
                    tracker.UpsertSyncState(chain.Name, new SyncStatePatch(null, null, null, "headers_syncing"));
                else
                    MarkHeadersCurrent(chain, tracker);
                break;
            }

            if (totalStored >= maxHeaders)
            {
                var currentState = tracker.GetSyncState(chain.Name);
                tracker.UpsertSyncState(chain.Name, new SyncStatePatch(null, null, (currentState?.BestHeight ?? 0) + 1, "headers_syncing"));
                break;
            }
        }

        var finalState = tracker.GetSyncState(chain.Name);
        var tip = finalState?.BestHeight ?? 0;
        var status = finalState?.SyncStatus ?? "starting";
        return new Result(totalStored, tip, status);
    }

    public static bool ShouldSkip(int peerHeight, int localHeight, int targetHeight = 0) =>
        peerHeight >= 0 && localHeight >= peerHeight - NearPeerTip && (targetHeight <= 0 || localHeight >= targetHeight);

    private static bool HeadersSyncDone(int bestHeight, int peerHeight, int batchCount, int targetHeight = 0) =>
        targetHeight > 0
            ? bestHeight >= targetHeight || batchCount == 0
            : batchCount == 0 || (peerHeight >= 0 && bestHeight >= peerHeight);

    private static int PersistHeaders(
        ChainParams chain,
        IChainstateStore tracker,
        IReadOnlyList<BlockHeader> headers,
        byte[] genesisHashInternal)
    {
        var state = tracker.GetSyncState(chain.Name);
        var tipHeight = state?.BestHeight ?? 0;
        var tipHashHex = tracker.GetHeaderHash(chain.Name, tipHeight) ?? chain.GenesisHash;
        var tipInternal = tipHeight == 0
            ? genesisHashInternal
            : Hex.Reverse(Hex.Decode(tipHashHex));

        var chainWork = BigInteger.Zero;

        var stored = 0;
        foreach (var header in headers)
        {
            try
            {
                HeaderValidator.ValidateHeader(header, tipInternal, chainWork);
            }
            catch (HeaderValidationException e)
            {
                tracker.LogEvent("sync", $"Header rejected at height {tipHeight + 1}: {e.Message}", "warning");
                break;
            }

            tipHeight += 1;
            var blockHash = BlockHeaderCodec.BlockHashHex(header);
            var prevHash = Hex.Encode(Hex.Reverse(header.PrevBlock));
            tracker.InsertHeader(chain.Name, tipHeight, blockHash, prevHash, Hex.Encode(BlockHeaderCodec.Serialize(header)));
            tracker.UpsertSyncState(
                chain.Name,
                new SyncStatePatch(tipHeight, blockHash, tipHeight + 1, "headers_syncing"));
            tipInternal = BlockHeaderCodec.BlockHash(header);
            stored += 1;
        }
        return stored;
    }

    private static void MarkHeadersCurrent(ChainParams chain, IChainstateStore tracker)
    {
        var state = tracker.GetSyncState(chain.Name);
        tracker.UpsertSyncState(
            chain.Name,
            new SyncStatePatch(state?.BestHeight, state?.BestHash, (state?.BestHeight ?? 0) + 1, "headers_current"));
    }
}
