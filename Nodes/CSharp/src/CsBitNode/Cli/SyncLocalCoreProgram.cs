using CsBitNode.Chain;
using CsBitNode.Consensus.Block;
using CsBitNode.Config;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.P2p;
using CsBitNode.Storage;
using CsBitNode.Sync;
using CsBitNode.Util;

namespace CsBitNode.Cli;

public static class SyncLocalCoreService
{
    public static int Run(TextWriter output, IReadOnlyDictionary<string, string?> env)
    {
        var chainName = env.GetValueOrDefault("CHAIN") ?? NodePaths.DefaultChain;
        var chain = ChainRegistry.Get(chainName);
        var peers = PeerConfig.ParsePeers(env.GetValueOrDefault("PEERS"), chain.DefaultPort);
        var maxHeaders = PeerConfig.ParseInt(env.GetValueOrDefault("HEADERS_MAX"), HeaderSync.DefaultMaxHeaders);
        var maxBatches = PeerConfig.ParseInt(env.GetValueOrDefault("HEADER_BATCHES_MAX"), HeaderSync.DefaultHeaderBatchesMax);
        var maxBlocks = PeerConfig.ParseInt(env.GetValueOrDefault("BLOCKS_MAX"), 128);
        var skipBlocks = PeerConfig.ParseBool(env.GetValueOrDefault("SKIP_BLOCKS"), false);
        var fixtureBlocksDir = env.GetValueOrDefault("FIXTURE_BLOCKS_DIR");

        var dataDir = NodePaths.DataDirFromEnv(env.GetValueOrDefault("DATA_DIR"));
        var peer = peers[0];

        output.WriteLine("csbitnode sync-local-core");
        output.WriteLine($"  chain={chain.Name}");
        output.WriteLine("  storage=native-rocksdb");
        output.WriteLine($"  peer={peer.Host}:{peer.Port}");
        output.WriteLine($"  headers_max={maxHeaders} batches_max={maxBatches}");
        output.WriteLine($"  blocks_max={maxBlocks} skip_blocks={skipBlocks}");

        try
        {
            return RunNative(output, chain, peer, maxHeaders, maxBatches, maxBlocks, skipBlocks, dataDir, fixtureBlocksDir);
        }
        catch (DatadirLockBusyException ex)
        {
            output.WriteLine("  sync_status=error");
            output.WriteLine($"  error={ex.Message}");
            PrintBestEffortStatus(output, chain.Name, dataDir);
            output.WriteLine("  binary_gate_status=not_attempted");
            return 2;
        }
        catch (Exception ex)
        {
            output.WriteLine("  sync_status=error");
            output.WriteLine($"  error={ex.Message}");
            PrintBestEffortStatus(output, chain.Name, dataDir);
            output.WriteLine("  binary_gate_status=not_attempted");
            return 1;
        }
    }

    private static int RunNative(
        TextWriter output,
        ChainParams chain,
        PeerConfig.PeerEndpoint peer,
        int maxHeaders,
        int maxBatches,
        int maxBlocks,
        bool skipBlocks,
        string dataDir,
        string? fixtureBlocksDir)
    {
        using var session = ChainstateSession.OpenNative(dataDir, chain);
        var tracker = session.Store;
        if (!string.IsNullOrWhiteSpace(fixtureBlocksDir))
        {
            var fixtureExitCode = 0;
            SeedFixtureHeaders(tracker, chain, fixtureBlocksDir);
            if (!skipBlocks)
            {
                var result = BlockSync.SyncFromBlockSource(new FixtureBlockSource(fixtureBlocksDir), chain, tracker, session.BlockStorage, maxBlocks);
                output.WriteLine($"  downloaded_blocks={result.Downloaded}");
                output.WriteLine($"  connected_blocks={result.Connected}");
                output.WriteLine($"  sync_status={result.SyncStatus}");
                if (result.SyncStatus is "blocked" or "failed")
                    fixtureExitCode = 3;
            }
            output.WriteLine($"  validated_height={tracker.GetValidatedHeight(chain.Name)}");
            output.WriteLine($"  utxo_count={tracker.UtxoCount(chain.Name)}");
            output.WriteLine($"chainstate_check backend={tracker.Metadata.BackendName} validated_height={tracker.GetValidatedHeight(chain.Name)} validated_hash={tracker.GetValidatedHash(chain.Name) ?? ""} chainstate_status={tracker.Metadata.Status} generation_id={tracker.Metadata.GenerationId} backend_utxo_count={tracker.UtxoCount(chain.Name)}");
            output.WriteLine("  binary_gate_status=not_attempted");
            return fixtureExitCode;
        }

        var startHeight = tracker.BootstrapStartHeight(chain.Name);
        using var connection = new PeerConnection(peer.Host, peer.Port, chain, tracker, startHeight);
        connection.Connect();

        var headerResult = HeaderSync.SyncFromPeer(connection, chain, tracker, maxHeaders, maxBatches);
        output.WriteLine($"  stored_headers={headerResult.StoredTotal}");
        output.WriteLine($"  header_height={headerResult.BestHeight}");
        output.WriteLine($"  sync_status={headerResult.SyncStatus}");

        var syncExitCode = 0;
        if (!skipBlocks)
        {
            var blockResult = BlockSync.SyncFromPeer(connection, chain, tracker, session.BlockStorage, maxBlocks);
            output.WriteLine($"  downloaded_blocks={blockResult.Downloaded}");
            output.WriteLine($"  connected_blocks={blockResult.Connected}");
            output.WriteLine($"  sync_status={blockResult.SyncStatus}");
            if (blockResult.BlockerMessage is not null)
                output.WriteLine($"  current_blocker={blockResult.BlockerMessage}");
            syncExitCode = blockResult.SyncStatus is "blocked" or "failed" ? 3 : 0;
        }

        output.WriteLine($"  validated_height={tracker.GetValidatedHeight(chain.Name)}");
        output.WriteLine($"  utxo_count={tracker.UtxoCount(chain.Name)}");
        output.WriteLine($"chainstate_check backend={tracker.Metadata.BackendName} validated_height={tracker.GetValidatedHeight(chain.Name)} validated_hash={tracker.GetValidatedHash(chain.Name) ?? ""} chainstate_status={tracker.Metadata.Status} generation_id={tracker.Metadata.GenerationId} backend_utxo_count={tracker.UtxoCount(chain.Name)}");
        output.WriteLine("  binary_gate_status=not_attempted");
        return syncExitCode;
    }

    private static void PrintBestEffortStatus(TextWriter output, string chain, string dataDir)
    {
        try
        {
            using var session = ChainstateSession.OpenNative(dataDir, ChainRegistry.Get(chain), acquireLock: false);
            var store = session.Store;
            var syncState = store.GetSyncState(chain);
            output.WriteLine($"  header_height={syncState?.BestHeight ?? 0}");
            output.WriteLine($"  validated_height={store.GetValidatedHeight(chain)}");
            output.WriteLine($"  stored_block_height={store.MaxStoredBlockHeight(chain)}");
            output.WriteLine($"  current_sync_status={syncState?.SyncStatus ?? "unknown"}");
            var blocker = store.CurrentBlockerJson(chain);
            if (!string.IsNullOrWhiteSpace(blocker))
                output.WriteLine($"  current_blocker_json={blocker}");
        }
        catch
        {
            // Best-effort only: preserve the original sync error as the authoritative failure.
        }
    }

    private static void SeedFixtureHeaders(IChainstateStore store, ChainParams chain, string fixtureBlocksDir)
    {
        store.EnsureGenesis(chain.Name, Genesis.ForChain(chain.Name), chain.GenesisHash);
        foreach (var path in Directory.GetFiles(fixtureBlocksDir, "block*_wire.hex").OrderBy(path => path))
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var heightText = name["block".Length..name.IndexOf("_wire", StringComparison.Ordinal)];
            if (!int.TryParse(heightText, out var height))
                continue;
            var payload = Hex.Decode(File.ReadAllText(path).Trim());
            var block = BlockDeserializer.Deserialize(payload);
            var hash = BlockHeaderCodec.BlockHashHex(block.Header);
            var prev = Hex.Encode(Hex.Reverse(block.Header.PrevBlock));
            store.InsertHeader(chain.Name, height, hash, prev, Hex.Encode(BlockHeaderCodec.Serialize(block.Header)));
            store.UpsertSyncState(chain.Name, new SyncStatePatch(height, hash, store.HeaderCount(chain.Name), "headers_current"));
        }
    }

    private sealed class FixtureBlockSource : BlockSync.IBlockSource
    {
        private readonly string _fixtureBlocksDir;

        public FixtureBlockSource(string fixtureBlocksDir) => _fixtureBlocksDir = fixtureBlocksDir;

        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            foreach (var path in Directory.GetFiles(_fixtureBlocksDir, "block*_wire.hex").OrderBy(path => path))
            {
                var payload = Hex.Decode(File.ReadAllText(path).Trim());
                var block = BlockDeserializer.Deserialize(payload);
                if (BlockHeaderCodec.BlockHash(block.Header).AsSpan().SequenceEqual(blockHashInternal))
                    return payload;
            }
            return null;
        }
    }
}

public static class SyncLocalCoreProgram
{
    public static int Run(string[] args)
    {
        var env = Environment.GetEnvironmentVariables()
            .Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString());
        return SyncLocalCoreService.Run(Console.Out, env);
    }
}
