using System.Text.Json;
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
        var blockPrefetchDepth = PeerConfig.ParseInt(env.GetValueOrDefault("BLOCK_PREFETCH_DEPTH"), 1);
        var skipBlocks = PeerConfig.ParseBool(env.GetValueOrDefault("SKIP_BLOCKS"), false);
        var syncTiming = PeerConfig.ParseBool(env.GetValueOrDefault("CSBITNODE_SYNC_TIMING"), false);
        var syncTimingLog = PeerConfig.ParseBool(env.GetValueOrDefault("CSBITNODE_SYNC_TIMING_LOG"), false);
        var progressJson = PeerConfig.ParseBool(env.GetValueOrDefault("CSBITNODE_PROGRESS_JSON"), false);
        var progressInterval = Math.Max(1, PeerConfig.ParseInt(env.GetValueOrDefault("PROGRESS_INTERVAL"), 250));
        var scriptRunnerMode = (env.GetValueOrDefault("SCRIPT_RUNNER_MODE") ?? "sequential").Trim().ToLowerInvariant();
        var parallelScriptRunner = scriptRunnerMode == "parallel";
        var fixtureBlocksDir = env.GetValueOrDefault("FIXTURE_BLOCKS_DIR");

        var dataDir = NodePaths.DataDirFromEnv(env.GetValueOrDefault("DATA_DIR"));
        var peer = peers[0];

        output.WriteLine("csbitnode sync-local-core");
        output.WriteLine($"  chain={chain.Name}");
        output.WriteLine("  storage=native-rocksdb");
        output.WriteLine($"  peer={peer.Host}:{peer.Port}");
        output.WriteLine($"  headers_max={maxHeaders} batches_max={maxBatches}");
        output.WriteLine($"  blocks_max={maxBlocks} block_prefetch_depth={blockPrefetchDepth} script_runner_mode={scriptRunnerMode} skip_blocks={skipBlocks}");

        try
        {
            return RunNative(output, chain, peer, maxHeaders, maxBatches, maxBlocks, blockPrefetchDepth, parallelScriptRunner, skipBlocks, dataDir, fixtureBlocksDir, syncTiming, syncTimingLog, progressJson, progressInterval);
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
        int blockPrefetchDepth,
        bool parallelScriptRunner,
        bool skipBlocks,
        string dataDir,
        string? fixtureBlocksDir,
        bool syncTiming,
        bool syncTimingLog,
        bool progressJson,
        int progressInterval)
    {
        using var session = ChainstateSession.OpenNative(dataDir, chain);
        var tracker = session.Store;
        var timingSink = syncTiming ? new ConsoleTimingSink(output, syncTimingLog) : null;
        if (!string.IsNullOrWhiteSpace(fixtureBlocksDir))
        {
            var fixtureExitCode = 0;
            SeedFixtureHeaders(tracker, chain, fixtureBlocksDir);
            if (!skipBlocks)
            {
                var result = BlockSync.SyncFromBlockSource(
                    new FixtureBlockSource(fixtureBlocksDir),
                    chain,
                    tracker,
                    session.BlockStorage,
                    maxBlocks,
                    timingSink,
                    blockPrefetchDepth,
                    parallelScriptRunner,
                    progressSink: progressJson
                        ? snapshot => PrintProgressJson(output, chain.Name, tracker, syncStateBestHeight: null, snapshot, progressInterval)
                        : null);
                output.WriteLine($"  downloaded_blocks={result.Downloaded}");
                output.WriteLine($"  connected_blocks={result.Connected}");
                output.WriteLine($"  sync_status={result.SyncStatus}");
                PersistTimingSummary(tracker, chain.Name, timingSink, output);
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
            var blockResult = BlockSync.SyncFromBlockSource(
                connection,
                chain,
                tracker,
                session.BlockStorage,
                maxBlocks,
                timingSink,
                blockPrefetchDepth,
                parallelScriptRunner,
                progressSink: progressJson
                    ? snapshot => PrintProgressJson(output, chain.Name, tracker, headerResult.BestHeight, snapshot, progressInterval)
                    : null);
            output.WriteLine($"  downloaded_blocks={blockResult.Downloaded}");
            output.WriteLine($"  connected_blocks={blockResult.Connected}");
            output.WriteLine($"  sync_status={blockResult.SyncStatus}");
            PersistTimingSummary(tracker, chain.Name, timingSink, output);
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

    private static void PersistTimingSummary(IChainstateStore tracker, string chain, ConsoleTimingSink? timingSink, TextWriter output)
    {
        if (timingSink is null)
            return;
        var summary = timingSink.Snapshot();
        tracker.SetSyncTimingSummary(chain, summary);
        output.WriteLine($"  timing_summary_json={JsonSerializer.Serialize(summary)}");
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

    private static void PrintProgressJson(
        TextWriter output,
        string chain,
        IChainstateStore tracker,
        int? syncStateBestHeight,
        BlockSync.ProgressSnapshot snapshot,
        int progressInterval)
    {
        if (snapshot.Height != 1 && snapshot.Height % progressInterval != 0)
            return;
        var syncState = tracker.GetSyncState(chain);
        var headerHeight = syncStateBestHeight ?? syncState?.BestHeight ?? snapshot.Height;
        var utxoCount = tracker.UtxoCount(chain);
        var progress = new Dictionary<string, object?>
        {
            ["chain"] = chain,
            ["sync_status"] = snapshot.SyncStatus,
            ["header_height"] = headerHeight,
            ["validated_height"] = snapshot.Height,
            ["validated_hash"] = snapshot.Hash,
            ["stored_block_height"] = tracker.MaxStoredBlockHeight(chain),
            ["utxo_count"] = utxoCount,
            ["chainstate_utxo_count"] = utxoCount,
            ["current_blocker"] = null,
            ["downloaded_blocks"] = snapshot.Downloaded,
            ["connected_blocks"] = snapshot.Connected,
        };
        var raw = JsonSerializer.Serialize(progress);
        output.WriteLine($"sync_progress_json={raw}");
        output.WriteLine($"rb.port_progress {raw}");
        output.Flush();
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

    private sealed class ConsoleTimingSink : SyncTimingCollector
    {
        private readonly TextWriter _output;
        private readonly bool _verbose;

        public ConsoleTimingSink(TextWriter output, bool verbose)
        {
            _output = output;
            _verbose = verbose;
        }

        public override void Record(string stage, int height, long elapsedTicks)
        {
            base.Record(stage, height, elapsedTicks);
            if (_verbose)
                _output.WriteLine($"  timing stage={stage} height={height} elapsed_us={TicksToMicros(elapsedTicks)} elapsed_ms={TicksToMillis(elapsedTicks)}");
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
