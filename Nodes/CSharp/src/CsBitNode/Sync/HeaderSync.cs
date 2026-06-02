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
        int maxBatches)
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
            if (ShouldSkip(peerHeight, bestHeight))
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
                MarkHeadersCurrent(chain, tracker);
                break;
            }

            var stored = PersistHeaders(chain, tracker, headers, genesisHashInternal);
            totalStored += stored;
            batches += 1;

            if (stored == 0 || HeadersSyncDone(bestHeight, peerHeight, headers.Count))
            {
                MarkHeadersCurrent(chain, tracker);
                break;
            }

            if (totalStored >= maxHeaders)
            {
                tracker.UpsertSyncState(chain.Name, new SyncStatePatch(null, null, tracker.HeaderCount(chain.Name), "headers_syncing"));
                break;
            }
        }

        var finalState = tracker.GetSyncState(chain.Name);
        var tip = finalState?.BestHeight ?? 0;
        var status = finalState?.SyncStatus ?? "starting";
        return new Result(totalStored, tip, status);
    }

    public static bool ShouldSkip(int peerHeight, int localHeight) =>
        peerHeight >= 0 && localHeight >= peerHeight - NearPeerTip;

    private static bool HeadersSyncDone(int bestHeight, int peerHeight, int batchCount) =>
        batchCount == 0 || (peerHeight >= 0 && bestHeight >= peerHeight);

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

        var chainWork = tipHeight == 0
            ? HeaderValidator.ChainWorkForHeader(Genesis.ForChain(chain.Name))
            : ChainWorkThroughHeight(chain, tracker, tipHeight);

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
            chainWork += HeaderValidator.ChainWorkForHeader(header);
            var blockHash = BlockHeaderCodec.BlockHashHex(header);
            var prevHash = Hex.Encode(Hex.Reverse(header.PrevBlock));
            tracker.InsertHeader(chain.Name, tipHeight, blockHash, prevHash, Hex.Encode(BlockHeaderCodec.Serialize(header)));
            tracker.UpsertSyncState(
                chain.Name,
                new SyncStatePatch(tipHeight, blockHash, tracker.HeaderCount(chain.Name), "headers_syncing"));
            tipInternal = BlockHeaderCodec.BlockHash(header);
            stored += 1;
        }
        return stored;
    }

    private static BigInteger ChainWorkThroughHeight(ChainParams chain, IChainstateStore tracker, int height)
    {
        var work = HeaderValidator.ChainWorkForHeader(Genesis.ForChain(chain.Name));
        for (var h = 1; h <= height; h++)
        {
            var hex = tracker.GetHeaderHash(chain.Name, h);
            if (hex is null)
                break;
            // Re-parse stored header for chainwork accumulation would be expensive; approximate by reading serialized hex
            var bytes = Hex.Decode(tracker.GetHeaderSerializedHex(chain.Name, h) ?? "");
            if (bytes.Length == 0)
                continue;
            var offset = 0;
            var header = BlockHeaderCodec.Deserialize(bytes, ref offset);
            work += HeaderValidator.ChainWorkForHeader(header);
        }
        return work;
    }

    private static void MarkHeadersCurrent(ChainParams chain, IChainstateStore tracker)
    {
        var state = tracker.GetSyncState(chain.Name);
        tracker.UpsertSyncState(
            chain.Name,
            new SyncStatePatch(state?.BestHeight, state?.BestHash, tracker.HeaderCount(chain.Name), "headers_current"));
    }
}
