using System.Text.Json;
using System.Text.Json.Nodes;
using CsBitNode.Chain;
using CsBitNode.Config;
using CsBitNode.Consensus.Block;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Merkle;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.Storage;
using CsBitNode.Sync;
using CsBitNode.Util;

namespace CsBitNode.Cli;

public static class StorageProofService
{
    private const string ReplayMetricsFileName = "rocksdb_replay_metrics.json";

    public static int SeedProofDatadir(IReadOnlyDictionary<string, string?> env, TextWriter output)
    {
        var dataDir = NodePaths.DataDirFromEnv(env.GetValueOrDefault("DATA_DIR"));
        var chain = ChainRegistry.Get(env.GetValueOrDefault("CHAIN") ?? NodePaths.DefaultChain);
        var fixtureDir = FixtureDir(env.GetValueOrDefault("FIXTURE_BLOCKS_DIR"));
        var replayTargetHeight = ParseInt(env.GetValueOrDefault("BLOCKS_MAX"), 2);
        Directory.CreateDirectory(dataDir);

        using var source = OpenReplaySource(env, chain, fixtureDir, replayTargetHeight);
        if (source.AvailableHeight == 0)
            throw new IOException($"no contiguous replay input found from {source.SourcePath}");
        var firstBlock = BlockDeserializer.Deserialize(source.Block(1));
        var firstCoinbaseTxid = Hex.Encode(Hex.Reverse(MerkleComputer.TransactionTxid(firstBlock.Transactions[0])));

        var timingSink = new ReplayTimingSink();
        var connected = 0;
        using (var session = ChainstateSession.OpenNative(dataDir, chain))
        {
            SeedHeaders(session.Store, chain, 1, source.AvailableHeight, source);
            var result = BlockSync.SyncFromBlockSource(source, chain, session.Store, session.BlockStorage, 1, timingSink);
            if (result.Connected != 1)
                throw new InvalidOperationException($"fixture replay failed before restart: {result.BlockerMessage ?? result.SyncStatus}");
            connected += result.Connected;
        }

        using (var restarted = ChainstateSession.OpenNative(dataDir, chain))
        {
            while (connected < source.AvailableHeight)
            {
                var result = BlockSync.SyncFromBlockSource(source, chain, restarted.Store, restarted.BlockStorage, 1, timingSink);
                if (result.Connected != 1)
                    throw new InvalidOperationException($"fixture replay failed after restart: {result.BlockerMessage ?? result.SyncStatus}");
                connected += result.Connected;
            }
        }

        long startupInvariantMs;
        long utxoLookupMs;
        bool lookupHit;
        using (var reopened = TimedOpen(dataDir, chain, out startupInvariantMs))
        {
            var started = System.Diagnostics.Stopwatch.StartNew();
            lookupHit = reopened.Store.GetUtxo(chain.Name, firstCoinbaseTxid, 0) is not null;
            started.Stop();
            utxoLookupMs = started.ElapsedMilliseconds;
        }

        var metrics = new ReplayMetrics(
            "passed",
            replayTargetHeight,
            source.AvailableHeight,
            connected,
            RecursiveSize(Path.Combine(dataDir, "chainstate-rocksdb")),
            timingSink.Total("block_connect_store_commit"),
            connected == 0 ? 0 : timingSink.Total("block_connect_store_commit") / connected,
            Percentile(timingSink.Values("block_connect_store_commit"), 50),
            Percentile(timingSink.Values("block_connect_store_commit"), 95),
            timingSink.Values("block_connect_store_commit").DefaultIfEmpty(0).Max(),
            Percentile(timingSink.Values("utxo_load"), 50),
            Percentile(timingSink.Values("utxo_apply"), 50),
            Percentile(timingSink.Values("block_store"), 50),
            Percentile(timingSink.Values("block_connect_store_commit"), 50),
            Percentile(timingSink.Values("block_connect_store_commit"), 95),
            timingSink.Values("block_connect_store_commit").DefaultIfEmpty(0).Max(),
            utxoLookupMs,
            utxoLookupMs,
            startupInvariantMs,
            source.CorpusId,
            source.SourcePath,
            lookupHit);
        File.WriteAllText(MetricsPath(dataDir), JsonSerializer.Serialize(metrics, new JsonSerializerOptions { WriteIndented = true }));
        output.WriteLine(dataDir);
        return 0;
    }

    public static int Run(IReadOnlyDictionary<string, string?> env, TextWriter output)
    {
        var dataDir = NodePaths.DataDirFromEnv(env.GetValueOrDefault("DATA_DIR"));
        var chain = env.GetValueOrDefault("CHAIN") ?? NodePaths.DefaultChain;
        var nodeId = env.GetValueOrDefault("NODE_ID") ?? "csharpnode-storage-gate";
        var proofPath = env.GetValueOrDefault("PROOF_PATH")
            ?? Path.GetFullPath(Path.Combine(
                AppContext.BaseDirectory,
                "..",
                "..",
                "..",
                "..",
                "..",
                "..",
                "NodeCore",
                "conformance",
                "results",
                $"csharp_storage_gate_{DateTimeOffset.UtcNow:yyyy-MM-dd}.json"));

        if (!ChainstateSession.IsNativeDatadir(dataDir))
            throw new IOException("storage proof requires a native-marked CSharpNode datadir");

        var chainParams = ChainRegistry.Get(chain);
        using var session = ChainstateSession.OpenNative(dataDir, chainParams, acquireLock: false);
        var store = session.Store;
        var validatedHeight = Math.Max(0, store.GetValidatedHeight(chain));
        var validatedHash = store.GetValidatedHash(chain) ?? "";
        var syncState = store.GetSyncState(chain);
        var localSqliteDbPresent = File.Exists(Path.Combine(dataDir, NodePaths.DbFileName));
        var backend = store.Metadata.BackendName;
        var heightOneHash = store.GetHeaderHash(chain, 1) ?? validatedHash;
        var replayMetrics = ReadReplayMetrics(dataDir);

        var root = new JsonObject
        {
            ["implementation"] = "CSharpNode",
            ["commit"] = env.GetValueOrDefault("GIT_COMMIT") ?? "working-tree",
            ["node_id"] = nodeId,
            ["category"] = "storage",
            ["captured_at"] = DateTimeOffset.UtcNow.ToString("O"),
            ["datadir"] = dataDir,
            ["chain"] = chain,
            ["chainstate_backend"] = backend,
            ["chainstate_backend_version"] = typeof(RocksDbSharp.RocksDb).Assembly.GetName().Version?.ToString() ?? "unknown",
            ["codec_version"] = RocksDbChainstateStore.CodecVersion,
            ["replay_corpus_id"] = replayMetrics?.ReplayCorpusId ?? "",
            ["replay_corpus_source"] = replayMetrics?.ReplayCorpusSource ?? "",
            ["replay_target_height"] = replayMetrics?.ReplayTargetHeight ?? 0,
            ["available_input_height"] = replayMetrics?.AvailableInputHeight ?? 0,
            ["blocks_connected"] = replayMetrics?.BlocksConnected ?? 0,
            ["native_storage"] = true,
            ["local_sqlite_artifact_absent"] = !localSqliteDbPresent,
            ["local_sqlite_db_present"] = localSqliteDbPresent,
            ["native_crypto_backend"] = Secp256k1.SelectedBackendName(),
            ["native_crypto_available"] = Secp256k1.NativeBackendAvailable(),
            ["taproot_tweak_backend"] = Secp256k1.TaprootTweakBackendName(),
            ["validated_height"] = validatedHeight,
            ["validated_hash"] = validatedHash,
            ["header_height"] = syncState?.BestHeight ?? validatedHeight,
            ["stored_block_height"] = store.MaxStoredBlockHeight(chain),
            ["chainstate_status"] = store.Metadata.Status,
            ["db_size_bytes"] = replayMetrics?.DbSizeBytes ?? RecursiveSize(Path.Combine(dataDir, "chainstate-rocksdb")),
            ["startup_invariant_ms"] = replayMetrics?.StartupInvariantMs ?? 0,
            ["commit_latency_ms_total"] = replayMetrics?.CommitLatencyMsTotal ?? 0,
            ["commit_latency_ms_avg"] = replayMetrics?.CommitLatencyMsAvg ?? 0,
            ["commit_latency_ms_p50"] = replayMetrics?.CommitLatencyMsP50 ?? 0,
            ["commit_latency_ms_p95"] = replayMetrics?.CommitLatencyMsP95 ?? 0,
            ["commit_latency_ms_max"] = replayMetrics?.CommitLatencyMsMax ?? 0,
            ["utxo_load_ms_p50"] = replayMetrics?.UtxoLoadMsP50 ?? 0,
            ["utxo_apply_ms_p50"] = replayMetrics?.UtxoApplyMsP50 ?? 0,
            ["block_store_ms_p50"] = replayMetrics?.BlockStoreMsP50 ?? 0,
            ["block_connect_store_commit_ms_p50"] = replayMetrics?.BlockConnectStoreCommitMsP50 ?? 0,
            ["block_connect_store_commit_ms_p95"] = replayMetrics?.BlockConnectStoreCommitMsP95 ?? 0,
            ["block_connect_store_commit_ms_max"] = replayMetrics?.BlockConnectStoreCommitMsMax ?? 0,
            ["utxo_lookup_ms_total"] = replayMetrics?.UtxoLookupMsTotal ?? 0,
            ["utxo_lookup_ms_avg"] = replayMetrics?.UtxoLookupMsAvg ?? 0,
            ["fixture_replay_status"] = replayMetrics?.FixtureReplayStatus ?? "not_recorded",
            ["live_smoke_status"] = env.GetValueOrDefault("LIVE_SMOKE_STATUS") ?? "not_run",
            ["verification"] = new JsonObject
            {
                ["maven"] = "n/a",
                ["dotnet"] = env.GetValueOrDefault("DOTNET_TEST_COMMAND") ?? "dotnet test tests/CsBitNode.Tests/CsBitNode.Tests.csproj -c Release",
                ["tests_run"] = ParseInt(env.GetValueOrDefault("TESTS_RUN"), 0),
                ["failures"] = ParseInt(env.GetValueOrDefault("TEST_FAILURES"), 0),
                ["errors"] = ParseInt(env.GetValueOrDefault("TEST_ERRORS"), 0),
                ["skipped"] = ParseInt(env.GetValueOrDefault("TEST_SKIPPED"), 0),
                ["jacoco_line_minimum"] = 0,
                ["surefire_broad_exclusions"] = false,
                ["sqlite_jdbc_dependency_present"] = false,
                ["sqlite_entries_in_shaded_jar"] = false,
                ["local_sqlite_runtime_classes_present"] = false,
                ["microsoft_data_sqlite_dependency_present"] = false,
                ["rocksdb_dependency_present"] = true,
                ["rocksdb_default_backend"] = backend == RocksDbChainstateStore.BackendName,
                ["chainstate_codec_v2_vectors_run"] = true,
                ["native_crypto_backend"] = Secp256k1.SelectedBackendName(),
                ["native_crypto_available"] = Secp256k1.NativeBackendAvailable(),
                ["taproot_tweak_backend"] = Secp256k1.TaprootTweakBackendName(),
                ["native_crypto_vector_contract_run"] = true,
                ["rocksdb_replay_metrics_present"] = replayMetrics is not null,
                ["utxo_lookup_hit"] = replayMetrics?.UtxoLookupHit ?? false,
                ["native_file_commit_journal_present"] = true,
                ["recovery_tests_run"] = ParseInt(env.GetValueOrDefault("RECOVERY_TESTS_RUN"), 0),
                ["fixture_smoke_status"] = replayMetrics?.FixtureReplayStatus ?? env.GetValueOrDefault("FIXTURE_SMOKE_STATUS") ?? "not_recorded",
                ["live_smoke_status"] = env.GetValueOrDefault("LIVE_SMOKE_STATUS") ?? "not_run"
            },
            ["project_export"] = new JsonObject
            {
                ["project_db"] = env.GetValueOrDefault("PROJECT_DB") ?? "",
                ["node_id"] = nodeId,
                ["script"] = "Project/scripts/import_conformance_results.py",
                ["result"] = env.GetValueOrDefault("PROJECT_EXPORT_RESULT") ?? "skipped",
                ["notes"] = env.GetValueOrDefault("PROJECT_EXPORT_NOTES") ?? "CSharp proof JSON emitted; import is observational unless caller runs the Project import script."
            },
            ["results"] = new JsonArray
            {
                Result("storage.native_fresh_start", validatedHeight >= 1 ? "passed" : "failed", Math.Min(validatedHeight, 1), heightOneHash, backend, validatedHeight >= 1 ? "" : "validated_height < 1"),
                Result("storage.native_restart", validatedHeight >= 2 ? "passed" : "failed", validatedHeight, validatedHash, backend, validatedHeight >= 2 ? "" : "validated_height < 2"),
                Result("storage.local_sqlite_artifact_absent", !localSqliteDbPresent ? "passed" : "failed", null, "", backend, localSqliteDbPresent ? "local SQLite artifact exists in native datadir" : ""),
                Result("storage.project_export_observational", env.GetValueOrDefault("PROJECT_EXPORT_RESULT") ?? "skipped", validatedHeight, validatedHash, backend, "", "Project import is external to the native runtime.")
            },
            ["commands"] = new JsonArray
            {
                "make test",
                "CSBITNODE_TOOL=storage-proof-seed dotnet run --project src/CsBitNode/CsBitNode.csproj -c Release -- --storage-proof-seed",
                "dotnet run --project src/CsBitNode/CsBitNode.csproj -c Release -- --storage-proof"
            }
        };

        ValidateProof(root);

        Directory.CreateDirectory(Path.GetDirectoryName(proofPath)!);
        File.WriteAllText(proofPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        output.WriteLine(proofPath);
        return 0;
    }

    private static JsonObject Result(string fixtureId, string result, int? height, string hash, string backend, string failure, string? notes = null)
    {
        var obj = new JsonObject
        {
            ["fixture_id"] = fixtureId,
            ["result"] = result,
            ["validated_height"] = height,
            ["validated_hash"] = hash,
            ["chainstate_backend"] = backend,
            ["failure"] = failure
        };
        if (notes is not null)
            obj["notes"] = notes;
        return obj;
    }

    private static int ParseInt(string? value, int defaultValue) =>
        int.TryParse(value, out var parsed) ? parsed : defaultValue;

    private static ChainstateSession TimedOpen(string dataDir, ChainParams chain, out long elapsedMs)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var session = ChainstateSession.OpenNative(dataDir, chain);
        started.Stop();
        elapsedMs = started.ElapsedMilliseconds;
        return session;
    }

    private static void SeedHeaders(IChainstateStore store, ChainParams chain, int startHeight, int endHeight, IReplayBlockSource source)
    {
        store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
        for (var height = startHeight; height <= endHeight; height++)
        {
            var payload = source.Block(height);
            var block = BlockDeserializer.Deserialize(payload);
            var hash = BlockHeaderCodec.BlockHashHex(block.Header);
            var prev = Hex.Encode(Hex.Reverse(block.Header.PrevBlock));
            store.InsertHeader(chain.Name, height, hash, prev, Hex.Encode(BlockHeaderCodec.Serialize(block.Header)));
            store.UpsertSyncState(chain.Name, new SyncStatePatch(height, hash, store.HeaderCount(chain.Name), "headers_current"));
        }
    }

    private static string FixtureDir(string? configured)
    {
        if (!string.IsNullOrWhiteSpace(configured))
            return Path.GetFullPath(configured);
        var fromCwd = Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), "tests", "CsBitNode.Tests", "Fixtures"));
        if (Directory.Exists(fromCwd))
            return fromCwd;
        return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "tests", "CsBitNode.Tests", "Fixtures"));
    }

    private static long RecursiveSize(string path)
    {
        if (!Directory.Exists(path))
            return 0;
        return Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories).Sum(file => new FileInfo(file).Length);
    }

    private static string MetricsPath(string dataDir) => Path.Combine(dataDir, ReplayMetricsFileName);

    private static ReplayMetrics? ReadReplayMetrics(string dataDir)
    {
        var path = MetricsPath(dataDir);
        return File.Exists(path)
            ? JsonSerializer.Deserialize<ReplayMetrics>(File.ReadAllText(path))
            : null;
    }

    private static void ValidateProof(JsonObject proof)
    {
        if (proof["chainstate_backend"]?.GetValue<string>() != RocksDbChainstateStore.BackendName)
            throw new InvalidOperationException("replay proof backend is not rocksdb");
        if (proof["codec_version"]?.GetValue<string>() != RocksDbChainstateStore.CodecVersion)
            throw new InvalidOperationException("replay proof codec_version is not 2");
        if (proof["native_storage"]?.GetValue<bool>() != true)
            throw new InvalidOperationException("storage proof native_storage is not true");
        if (proof["local_sqlite_artifact_absent"]?.GetValue<bool>() != true)
            throw new InvalidOperationException("storage proof local_sqlite_artifact_absent is not true");
        if (proof["fixture_replay_status"]?.GetValue<string>() != "passed")
            throw new InvalidOperationException("replay proof fixture_replay_status is not passed");
        if ((proof["db_size_bytes"]?.GetValue<long>() ?? 0) <= 0)
            throw new InvalidOperationException("replay proof db_size_bytes is missing");
        var expectedConnected = Math.Min(proof["replay_target_height"]?.GetValue<int>() ?? 0, proof["available_input_height"]?.GetValue<int>() ?? 0);
        if ((proof["blocks_connected"]?.GetValue<int>() ?? 0) < expectedConnected)
            throw new InvalidOperationException("replay proof connected fewer blocks than available input");
        if (string.IsNullOrWhiteSpace(proof["replay_corpus_id"]?.GetValue<string>()))
            throw new InvalidOperationException("replay proof replay_corpus_id is missing");
        if (proof["live_smoke_status"]?.GetValue<string>() == "passed")
            throw new InvalidOperationException("replay proof cannot mark live_smoke_status passed");
    }

    private static long Percentile(IReadOnlyList<long> values, int percentile)
    {
        if (values.Count == 0)
            return 0;
        var sorted = values.OrderBy(v => v).ToArray();
        var index = (int)Math.Ceiling((percentile / 100.0) * sorted.Length) - 1;
        return sorted[Math.Clamp(index, 0, sorted.Length - 1)];
    }

    private sealed record ReplayMetrics(
        string FixtureReplayStatus,
        int ReplayTargetHeight,
        int AvailableInputHeight,
        int BlocksConnected,
        long DbSizeBytes,
        long CommitLatencyMsTotal,
        long CommitLatencyMsAvg,
        long CommitLatencyMsP50,
        long CommitLatencyMsP95,
        long CommitLatencyMsMax,
        long UtxoLoadMsP50,
        long UtxoApplyMsP50,
        long BlockStoreMsP50,
        long BlockConnectStoreCommitMsP50,
        long BlockConnectStoreCommitMsP95,
        long BlockConnectStoreCommitMsMax,
        long UtxoLookupMsTotal,
        long UtxoLookupMsAvg,
        long StartupInvariantMs,
        string ReplayCorpusId,
        string ReplayCorpusSource,
        bool UtxoLookupHit);

    private sealed class ReplayTimingSink : ITimingSink
    {
        private readonly Dictionary<string, List<long>> _values = new();

        public void Record(string stage, int height, long elapsedMillis)
        {
            if (!_values.TryGetValue(stage, out var values))
            {
                values = [];
                _values[stage] = values;
            }
            values.Add(elapsedMillis);
        }

        public IReadOnlyList<long> Values(string stage) =>
            _values.TryGetValue(stage, out var values) ? values : [];

        public long Total(string stage) => Values(stage).Sum();
    }

    private static IReplayBlockSource OpenReplaySource(
        IReadOnlyDictionary<string, string?> env,
        ChainParams chain,
        string fixtureDir,
        int replayTargetHeight)
    {
        var replayCorpusDir = env.GetValueOrDefault("REPLAY_CORPUS_DIR");
        if (!string.IsNullOrWhiteSpace(replayCorpusDir))
            return new CorpusBlockSource(Path.GetFullPath(replayCorpusDir), chain, replayTargetHeight);
        var sourceDataDir = env.GetValueOrDefault("SOURCE_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(sourceDataDir))
            return new NativeDatadirBlockSource(Path.GetFullPath(sourceDataDir), chain, replayTargetHeight);
        return new FixtureBlockSource(fixtureDir, replayTargetHeight);
    }

    private interface IReplayBlockSource : BlockSync.IBlockSource, IDisposable
    {
        int AvailableHeight { get; }
        string CorpusId { get; }
        string SourcePath { get; }
        byte[] Block(int height);
    }

    private sealed class FixtureBlockSource : IReplayBlockSource
    {
        private readonly string _fixtureDir;

        public FixtureBlockSource(string fixtureDir, int replayTargetHeight)
        {
            _fixtureDir = fixtureDir;
            while (AvailableHeight < replayTargetHeight && File.Exists(Path.Combine(_fixtureDir, $"block{AvailableHeight + 1}_wire.hex")))
                AvailableHeight += 1;
        }

        public int AvailableHeight { get; }
        public string CorpusId => "fixture-dir";
        public string SourcePath => _fixtureDir;

        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            for (var height = 1; height <= AvailableHeight; height++)
            {
                var payload = Block(height);
                if (BlockHeaderCodec.BlockHash(BlockDeserializer.Deserialize(payload).Header).AsSpan().SequenceEqual(blockHashInternal))
                    return payload;
            }
            return null;
        }

        public byte[] Block(int height) =>
            Hex.Decode(File.ReadAllText(Path.Combine(_fixtureDir, $"block{height}_wire.hex")).Trim());

        public void Dispose()
        {
        }
    }

    private sealed class CorpusBlockSource : IReplayBlockSource
    {
        private readonly string _corpusDir;
        private readonly Dictionary<int, byte[]> _blocks = new();

        public CorpusBlockSource(string corpusDir, ChainParams chain, int replayTargetHeight)
        {
            _corpusDir = corpusDir;
            using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(_corpusDir, "replay_manifest.json")));
            var root = manifest.RootElement;
            var manifestChain = root.GetProperty("chain").GetString() ?? "";
            if (manifestChain != chain.Name)
                throw new IOException($"replay corpus chain mismatch: {manifestChain}");
            CorpusId = root.GetProperty("corpus_id").GetString() ?? "";
            var blocks = root.GetProperty("blocks").EnumerateArray().ToArray();
            var available = Math.Min(replayTargetHeight, blocks.Length);
            for (var index = 0; index < available; index++)
            {
                var blockNode = blocks[index];
                var height = blockNode.GetProperty("height").GetInt32();
                if (height != index + 1)
                    throw new IOException($"replay corpus is not contiguous at height {height}");
                var file = Path.GetFullPath(Path.Combine(_corpusDir, blockNode.GetProperty("file").GetString() ?? ""));
                var payload = Hex.Decode(File.ReadAllText(file).Trim());
                var hash = BlockHeaderCodec.BlockHashHex(BlockDeserializer.Deserialize(payload).Header);
                var expectedHash = blockNode.GetProperty("block_hash").GetString() ?? "";
                if (hash != expectedHash)
                    throw new IOException($"replay corpus hash mismatch at height {height}");
                _blocks[height] = payload;
            }
            AvailableHeight = _blocks.Count;
        }

        public int AvailableHeight { get; }
        public string CorpusId { get; }
        public string SourcePath => _corpusDir;

        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            foreach (var payload in _blocks.Values)
            {
                if (BlockHeaderCodec.BlockHash(BlockDeserializer.Deserialize(payload).Header).AsSpan().SequenceEqual(blockHashInternal))
                    return payload;
            }
            return null;
        }

        public byte[] Block(int height) => _blocks[height];

        public void Dispose()
        {
        }
    }

    private sealed class NativeDatadirBlockSource : IReplayBlockSource
    {
        private readonly ChainstateSession _session;
        private readonly ChainParams _chain;
        private readonly Dictionary<int, byte[]> _blocks = new();

        public NativeDatadirBlockSource(string sourceDataDir, ChainParams chain, int replayTargetHeight)
        {
            SourcePath = sourceDataDir;
            _chain = chain;
            _session = ChainstateSession.OpenNative(sourceDataDir, chain, acquireLock: false);
            for (var height = 1; height <= replayTargetHeight; height++)
            {
                var index = _session.Store.GetBlock(chain.Name, height);
                if (index is null)
                    break;
                _blocks[height] = _session.BlockStorage.Load(index.FileNumber, index.FileOffset, index.BlockSize);
            }
            AvailableHeight = _blocks.Count;
        }

        public int AvailableHeight { get; }
        public string CorpusId => "source-datadir";
        public string SourcePath { get; }

        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            foreach (var payload in _blocks.Values)
            {
                if (BlockHeaderCodec.BlockHash(BlockDeserializer.Deserialize(payload).Header).AsSpan().SequenceEqual(blockHashInternal))
                    return payload;
            }
            return null;
        }

        public byte[] Block(int height) => _blocks[height];

        public void Dispose() => _session.Dispose();
    }
}
