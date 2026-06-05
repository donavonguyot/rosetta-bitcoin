using System.Collections.Concurrent;
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
        ITimingSink? timingSink = null,
        int prefetchDepth = 1,
        bool parallelScriptRunner = false)
    {
        var downloaded = 0;
        var connected = 0;
        ValidationBlocker? blocker = null;
        string syncStatus = "blocks_syncing";
        var validatedHeight = tracker.GetValidatedHeight(chain.Name);
        var prevHashHex = validatedHeight >= 0 ? tracker.GetValidatedHash(chain.Name) : null;
        using var prefetcher = prefetchDepth > 1
            ? new PrefetchingBlockSource(blockSource, chain, tracker, validatedHeight, maxBlocks, prefetchDepth)
            : null;
        var effectiveBlockSource = (IBlockSource?)prefetcher ?? blockSource;

        while (maxBlocks <= 0 || connected < maxBlocks)
        {
            var nextHeight = validatedHeight + 1;
            var headerHashHex = tracker.GetHeaderHash(chain.Name, nextHeight)
                ?? throw new InvalidOperationException($"missing header at height {nextHeight}");

            byte[] prevInternal;
            if (nextHeight == 0)
                prevInternal = new byte[32];
            else
            {
                prevHashHex ??= tracker.GetHeaderHash(chain.Name, nextHeight - 1)
                    ?? throw new InvalidOperationException($"missing prev header at {nextHeight - 1}");
                prevInternal = Hex.Reverse(Hex.Decode(prevHashHex));
            }

            var blockHashInternal = Hex.Reverse(Hex.Decode(headerHashHex));

            var payload = effectiveBlockSource.RequestBlock(blockHashInternal);
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
            timingSink?.Record("block_store", nextHeight, storeStarted.ElapsedTicks);

            try
            {
                var connectResult = BlockConnector.Connect(
                    tracker,
                    chain.Name,
                    nextHeight,
                    payload,
                    prevInternal,
                    blockHashInternal,
                    (stage, height, elapsedTicks) => timingSink?.Record(stage, height, elapsedTicks),
                    expectedValidatedHeight: validatedHeight,
                    storedBlock: new ChainstateBlockStorageIndex(stored.FileNumber, stored.FileOffset, stored.BlockSize),
                    parallelScriptRunner: parallelScriptRunner,
                    shapeSink: (height, shape) => timingSink?.RecordBlockShape(height, shape));
                blockStarted.Stop();
                timingSink?.Record("block_connect_store_commit", nextHeight, blockStarted.ElapsedTicks);
                connected += 1;
                validatedHeight = connectResult.Height;
                prevHashHex = connectResult.BlockHashHex;
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

    private sealed class PrefetchingBlockSource : IBlockSource, IDisposable
    {
        private readonly BlockingCollection<PrefetchedBlock> _queue;
        private readonly CancellationTokenSource _cancel = new();
        private readonly Thread _worker;

        public PrefetchingBlockSource(
            IBlockSource inner,
            ChainParams chain,
            IChainstateStore tracker,
            int validatedHeight,
            int maxBlocks,
            int prefetchDepth)
        {
            _queue = new BlockingCollection<PrefetchedBlock>(Math.Max(1, prefetchDepth));
            _worker = new Thread(() => Run(inner, chain, tracker, validatedHeight, maxBlocks))
            {
                IsBackground = true,
                Name = "csbitnode-block-prefetch"
            };
            _worker.Start();
        }

        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            PrefetchedBlock item;
            try
            {
                item = _queue.Take(_cancel.Token);
            }
            catch (InvalidOperationException)
            {
                return null;
            }
            catch (OperationCanceledException)
            {
                return null;
            }

            if (item.Error is not null)
                throw item.Error;
            if (!item.HashInternal.AsSpan().SequenceEqual(blockHashInternal))
                throw new InvalidOperationException(
                    $"prefetched block hash mismatch at height {item.Height}: got {Hex.Encode(Hex.Reverse(item.HashInternal))}, expected {Hex.Encode(Hex.Reverse(blockHashInternal))}");
            return item.Payload;
        }

        private void Run(IBlockSource inner, ChainParams chain, IChainstateStore tracker, int validatedHeight, int maxBlocks)
        {
            try
            {
                var limit = maxBlocks <= 0 ? int.MaxValue : maxBlocks;
                for (var offset = 0; offset < limit && !_cancel.IsCancellationRequested; offset++)
                {
                    var height = validatedHeight + 1 + offset;
                    var headerHashHex = tracker.GetHeaderHash(chain.Name, height);
                    if (headerHashHex is null)
                    {
                        Add(new PrefetchedBlock(height, [], null, new InvalidOperationException($"missing header at height {height}")));
                        break;
                    }
                    var hashInternal = Hex.Reverse(Hex.Decode(headerHashHex));
                    var payload = inner.RequestBlock(hashInternal);
                    Add(new PrefetchedBlock(height, hashInternal, payload, null));
                    if (payload is null)
                        break;
                }
            }
            catch (Exception error)
            {
                Add(new PrefetchedBlock(-1, [], null, error));
            }
            finally
            {
                _queue.CompleteAdding();
            }
        }

        private void Add(PrefetchedBlock block)
        {
            try
            {
                _queue.Add(block, _cancel.Token);
            }
            catch (OperationCanceledException)
            {
            }
            catch (InvalidOperationException)
            {
            }
        }

        public void Dispose()
        {
            _cancel.Cancel();
            _queue.Dispose();
            _cancel.Dispose();
        }
    }

    private sealed record PrefetchedBlock(int Height, byte[] HashInternal, byte[]? Payload, Exception? Error);
}

public sealed record BlockSyncResult(int Downloaded, int Connected, string SyncStatus, string? BlockerMessage);
