using CsBitNode.Chain;
using CsBitNode.Consensus;
using CsBitNode.Consensus.Block;
using CsBitNode.Consensus.Connect;
using CsBitNode.Consensus.Tx;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.Storage;
using CsBitNode.Sync;
using CsBitNode.Util;
using System.Text.Json;

namespace CsBitNode.Tests.Db;

public class NativeChainstateStoreTests
{
    [Fact]
    public void NativeStorePersistsMetadataTipUtxosUndoAndBlockIndex()
    {
        var dir = TempDir();
        using (var session = ChainstateSession.OpenNative(dir, ChainRegistry.Get("testnet4")))
        {
            var store = session.Store;
            store.EnsureGenesis("testnet4", Genesis.Testnet4, Genesis.Testnet4Hash);
            store.RecordBlock("testnet4", 1, "abababababababababababababababababababababababababababababababab", 0, 0, 42);
            store.CommitBlock(new ChainstateBlockCommit(
                "testnet4",
                1,
                "abababababababababababababababababababababababababababababababab",
                [],
                [new StoredUtxo("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", 0, 1, 50, "51", true)],
                []));

            Assert.True(File.Exists(ChainstateSession.NativeMarkerPath(dir)));
            Assert.Equal("rocksdb", store.Metadata.BackendName);
            Assert.Equal(1, store.GetValidatedHeight("testnet4"));
            Assert.Equal(1, store.UtxoCount("testnet4"));
            Assert.NotNull(store.GetBlock("testnet4", 1));
        }

        using (var reopened = ChainstateSession.OpenNative(dir, ChainRegistry.Get("testnet4")))
        {
            var store = reopened.Store;
            Assert.Equal(1, store.GetValidatedHeight("testnet4"));
            Assert.Equal("abababababababababababababababababababababababababababababababab", store.GetValidatedHash("testnet4"));
            Assert.NotNull(store.GetUtxo("testnet4", "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", 0));
            Assert.Equal(1, store.MaxStoredBlockHeight("testnet4"));
        }
    }

    [Fact]
    public void NativeStoreMaintainsCountersAndOrderedMultiGet()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using (var session = ChainstateSession.OpenNative(dir, chain))
        {
            var store = session.Store;
            store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
            Assert.Equal(1, store.HeaderCount(chain.Name));
            Assert.Equal(0, store.BlockCount(chain.Name));
            Assert.Equal(0, store.UtxoCount(chain.Name));

            store.RecordBlock(chain.Name, 1, "1111111111111111111111111111111111111111111111111111111111111111", 0, 0, 80);
            store.CommitBlock(new ChainstateBlockCommit(
                chain.Name,
                1,
                "1111111111111111111111111111111111111111111111111111111111111111",
                [],
                [
                    new StoredUtxo("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, 1, 50, "51", true),
                    new StoredUtxo("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1, 1, 25, "0014a54e2a1ec06389203887661535ed118b7d053889", false)
                ],
                []));

            Assert.Equal(1, store.BlockCount(chain.Name));
            Assert.Equal(1, store.MaxStoredBlockHeight(chain.Name));
            Assert.Equal(2, store.UtxoCount(chain.Name));

            var values = store.GetUtxos(chain.Name,
            [
                new UtxoOutpoint("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1),
                new UtxoOutpoint("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", 0),
                new UtxoOutpoint("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0),
                new UtxoOutpoint("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1)
            ]);
            Assert.Equal(4, values.Count);
            Assert.Equal(25, values[0]!.ValueSats);
            Assert.Null(values[1]);
            Assert.Equal(50, values[2]!.ValueSats);
            Assert.Equal(25, values[3]!.ValueSats);

            store.RecordBlock(chain.Name, 2, "2222222222222222222222222222222222222222222222222222222222222222", 0, 80, 80);
            store.CommitBlock(new ChainstateBlockCommit(
                chain.Name,
                2,
                "2222222222222222222222222222222222222222222222222222222222222222",
                [new UtxoOutpoint("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0)],
                [new StoredUtxo("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 0, 2, 40, "51", false)],
                [new UtxoUndoEntry("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, 1, 50, "51", true)]));
            Assert.Equal(2, store.UtxoCount(chain.Name));
        }

        using (var reopened = ChainstateSession.OpenNative(dir, chain))
        {
            Assert.Equal(1, reopened.Store.HeaderCount(chain.Name));
            Assert.Equal(2, reopened.Store.BlockCount(chain.Name));
            Assert.Equal(2, reopened.Store.MaxStoredBlockHeight(chain.Name));
            Assert.Equal(2, reopened.Store.UtxoCount(chain.Name));
            Assert.Null(reopened.Store.GetUtxo(chain.Name, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0));
            Assert.NotNull(reopened.Store.GetUtxo(chain.Name, "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", 0));
        }
    }

    [Fact]
    public void CommitBlockCanAtomicallyRecordBlockIndex()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using var session = ChainstateSession.OpenNative(dir, chain);
        var store = session.Store;
        store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

        store.CommitBlock(new ChainstateBlockCommit(
            chain.Name,
            1,
            "1212121212121212121212121212121212121212121212121212121212121212",
            [],
            [new StoredUtxo("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, 1, 50, "51", true)],
            [],
            new ChainstateBlockStorageIndex(3, 44, 88)));

        var index = store.GetBlock(chain.Name, 1);
        Assert.NotNull(index);
        Assert.Equal(3, index!.FileNumber);
        Assert.Equal(44, index.FileOffset);
        Assert.Equal(88, index.BlockSize);
        Assert.Equal(1, store.BlockCount(chain.Name));
        Assert.Equal(1, store.MaxStoredBlockHeight(chain.Name));
        Assert.Equal(1, store.GetValidatedHeight(chain.Name));
    }

    [Fact]
    public void FileBackendCommitJournalRestoresBlockIndex()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using (var session = ChainstateSession.OpenNative(dir, chain))
                session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

            var journalPath = Path.Combine(dir, "chainstate-file", "commit_pending.json");
            File.WriteAllText(journalPath, JsonSerializer.Serialize(new
            {
                Chain = chain.Name,
                Height = 1,
                BlockHashHex = "3434343434343434343434343434343434343434343434343434343434343434",
                SpentOutpoints = Array.Empty<UtxoOutpoint>(),
                CreatedUtxos = new[] { new StoredUtxo("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 0, 1, 25, "51", true) },
                UndoEntries = Array.Empty<UtxoUndoEntry>(),
                StoredBlock = new ChainstateBlockStorageIndex(7, 99, 101)
            }));

            using var reopened = ChainstateSession.OpenNative(dir, chain);
            var index = reopened.Store.GetBlock(chain.Name, 1);
            Assert.NotNull(index);
            Assert.Equal(7, index!.FileNumber);
            Assert.Equal(99, index.FileOffset);
            Assert.Equal(101, index.BlockSize);
            Assert.Equal(1, reopened.Store.GetValidatedHeight(chain.Name));
        });
    }

    [Fact]
    public void BlockSyncDoesNotRecordBlockIndexBeforeFailedConnect()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using var session = ChainstateSession.OpenNative(dir, chain);
        var store = session.Store;
        SeedHeaders(store, chain, 1);

        var result = BlockSync.SyncFromBlockSource(new WrongFixtureBlockSource(), chain, store, session.BlockStorage, 1);

        Assert.Equal("failed", result.SyncStatus);
        Assert.Equal(0, store.GetValidatedHeight(chain.Name));
        Assert.Null(store.GetBlock(chain.Name, 1));
    }

    [Fact]
    public void SyncTimingCollectorKeepsSubMillisecondAggregates()
    {
        var collector = new SyncTimingCollector();
        var oneHundredMicros = Math.Max(1, System.Diagnostics.Stopwatch.Frequency / 10_000);
        collector.Record("commit", 1, oneHundredMicros);

        var summary = collector.Snapshot();
        var commit = summary.Stages["commit"];
        Assert.Equal("microseconds", summary.Unit);
        Assert.True(commit.TotalMicros is > 0 and < 1000);
        Assert.Equal(commit.TotalMicros, commit.P50Micros);
        Assert.Equal(commit.TotalMicros, commit.P95Micros);
        Assert.Equal(commit.TotalMicros, commit.MaxMicros);
    }

    [Fact]
    public void StatusIncludesPersistedTimingSummary()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using (var session = ChainstateSession.OpenNative(dir, chain))
        {
            session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
            session.Store.SetSyncTimingSummary(
                chain.Name,
                new SyncTimingSummary(
                    "microseconds",
                    new Dictionary<string, SyncTimingStageSummary>
                    {
                        ["commit"] = new(1, 123, 123, 123, 123)
                    }));
        }

        var status = Cli.NodeStatusService.BuildStatus(chain.Name, dir);
        var timing = status["sync_timing"]!.AsObject();
        Assert.Equal("microseconds", timing["Unit"]!.GetValue<string>());
        Assert.Equal(123, timing["Stages"]!["commit"]!["TotalMicros"]!.GetValue<long>());
    }

    [Fact]
    public void BlockConnectorRejectsUnexpectedExpectedTip()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using var session = ChainstateSession.OpenNative(dir, chain);
        var store = session.Store;
        store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

        var block1 = FixtureBlock(1);
        var block1Hash = BlockHashInternal(block1);
        var error = Assert.Throws<ConnectBlockException>(() => BlockConnector.Connect(
            store,
            chain.Name,
            1,
            block1,
            BlockHeaderCodec.BlockHash(Genesis.Testnet4),
            block1Hash,
            expectedValidatedHeight: 5));
        Assert.Contains("validated tip 5", error.Message);
    }

    [Fact]
    public void BlockUtxoViewSkipsSameBlockPrevoutsDuringPrefetch()
    {
        var txidInternal = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var sameBlockOutpoint = ViewOutpoint.FromInternal(txidInternal, 0);
        var store = new CountingChainstateStore();
        var view = new BlockUtxoView(store, "testnet4", 1, [sameBlockOutpoint]);

        view.PrefetchExternal([new OutPoint(txidInternal, 0)]);

        Assert.Equal(0, store.GetUtxosCalls);
        Assert.Null(view.Get(new OutPoint(txidInternal, 0)));
        Assert.Equal(0, store.GetUtxoCalls);
    }

    [Fact]
    public void BlockUtxoViewLoadsExternalPrevoutsOnce()
    {
        var txidInternal = Enumerable.Range(32, 32).Select(i => (byte)i).ToArray();
        var outpoint = ViewOutpoint.FromInternal(txidInternal, 2);
        var store = new CountingChainstateStore();
        store.Utxos[outpoint.ToUtxoOutpoint()] = new StoredUtxo(outpoint.TxidHex(), 2, 1, 99, "51", false);
        var view = new BlockUtxoView(store, "testnet4", 2);

        view.PrefetchExternal([new OutPoint(txidInternal, 2), new OutPoint(txidInternal, 2)]);
        var loaded = view.Get(new OutPoint(txidInternal, 2));

        Assert.Equal(1, store.GetUtxosCalls);
        Assert.Single(store.LastGetUtxosRequest);
        Assert.NotNull(loaded);
        Assert.Equal(99, loaded!.ValueSats);
        Assert.Equal(0, store.GetUtxoCalls);
    }

    [Fact]
    public void FileBackendMultiGetMatchesOrderedFallback()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using var session = ChainstateSession.OpenNative(dir, chain);
            session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
            session.Store.CommitBlock(new ChainstateBlockCommit(
                chain.Name,
                1,
                "abababababababababababababababababababababababababababababababab",
                [],
                [new StoredUtxo("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 0, 1, 10, "51", true)],
                []));

            var values = session.Store.GetUtxos(chain.Name,
            [
                new UtxoOutpoint("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", 0),
                new UtxoOutpoint("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 0)
            ]);
            Assert.Null(values[0]);
            Assert.Equal(10, values[1]!.ValueSats);
        });
    }

    [Fact]
    public void BlockConnectorConnectsEarlyFixtureBlocksThroughNativeStore()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using var session = ChainstateSession.OpenNative(dir, chain);
        var store = session.Store;
        store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

        var block1 = FixtureBlock(1);
        var block1Hash = BlockHashInternal(block1);
        var result1 = BlockConnector.Connect(
            store,
            chain.Name,
            1,
            block1,
            BlockHeaderCodec.BlockHash(Genesis.Testnet4),
            block1Hash);

        var block2 = FixtureBlock(2);
        var block2Hash = BlockHashInternal(block2);
        var result2 = BlockConnector.Connect(
            store,
            chain.Name,
            2,
            block2,
            block1Hash,
            block2Hash);

        Assert.Equal(1, result1.Height);
        Assert.Equal(2, result2.Height);
        Assert.Equal(2, store.GetValidatedHeight(chain.Name));
        Assert.Equal(4, store.UtxoCount(chain.Name));
        Assert.False(File.Exists(Path.Combine(dir, "csbitnode.db")));
    }

    [Fact]
    public void BlockSyncConnectsFixturesAndSurvivesRestart()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using (var session = ChainstateSession.OpenNative(dir, chain))
        {
            var store = session.Store;
            SeedHeaders(store, chain, 1, 2);
            var result = BlockSync.SyncFromBlockSource(new FixtureBlockSource(), chain, store, session.BlockStorage, 1);
            Assert.Equal(1, result.Connected);
            Assert.Equal(1, store.GetValidatedHeight(chain.Name));
        }

        using (var reopened = ChainstateSession.OpenNative(dir, chain))
        {
            var result = BlockSync.SyncFromBlockSource(new FixtureBlockSource(), chain, reopened.Store, reopened.BlockStorage, 1);
            Assert.Equal(1, result.Connected);
            Assert.Equal(2, reopened.Store.GetValidatedHeight(chain.Name));
            Assert.Equal(2, reopened.Store.MaxStoredBlockHeight(chain.Name));
        }
    }

    [Fact]
    public void StatusUsesNativeFieldsAndNativeOpenFailsWhenSqliteArtifactExists()
    {
        var dir = TempDir();
        var chain = ChainRegistry.Get("testnet4");
        using (var session = ChainstateSession.OpenNative(dir, chain))
            session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

        File.WriteAllText(Path.Combine(dir, ".csbitnode.lock"), "999999 stale-lock");
        var status = Cli.NodeStatusService.BuildStatus(chain.Name, dir);
        Assert.True(status["sqlite_free"]!.GetValue<bool>());
        Assert.Equal("rocksdb", status["chainstate_backend"]!.GetValue<string>());
        Assert.Equal(0, status["validated_height"]!.GetValue<int>());
        Assert.Equal("idle", status["runtime_status"]!.GetValue<string>());

        File.WriteAllText(Path.Combine(dir, "csbitnode.db"), "");
        Assert.Throws<IOException>(() => ChainstateSession.OpenNative(dir, chain));
    }

    [Fact]
    public void StartupRecoversPendingCommitJournal()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using (var session = ChainstateSession.OpenNative(dir, chain))
            {
                session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
                session.Store.RecordBlock(chain.Name, 1, "aa", 0, 0, 1);
            }

            var journalPath = Path.Combine(dir, "chainstate-file", "commit_pending.json");
            File.WriteAllText(journalPath, JsonSerializer.Serialize(new
            {
                Chain = chain.Name,
                Height = 1,
                BlockHashHex = "aa",
                SpentOutpoints = Array.Empty<UtxoOutpoint>(),
                CreatedUtxos = new[] { new StoredUtxo("journal-tx", 0, 1, 25, "51", true) },
                UndoEntries = Array.Empty<UtxoUndoEntry>()
            }));

            using var reopened = ChainstateSession.OpenNative(dir, chain);
            Assert.Equal(1, reopened.Store.GetValidatedHeight(chain.Name));
            Assert.Equal("aa", reopened.Store.GetValidatedHash(chain.Name));
            Assert.NotNull(reopened.Store.GetUtxo(chain.Name, "journal-tx", 0));
            Assert.False(File.Exists(journalPath));
        });
    }

    [Fact]
    public void StartupRemovesStaleTempFiles()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using (var session = ChainstateSession.OpenNative(dir, chain))
                session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

            var tempPath = Path.Combine(dir, "chainstate-file", "utxos", chain.Name, "stale.json.tmp");
            Directory.CreateDirectory(Path.GetDirectoryName(tempPath)!);
            File.WriteAllText(tempPath, "partial");

            using var reopened = ChainstateSession.OpenNative(dir, chain);
            Assert.False(File.Exists(tempPath));
        });
    }

    [Fact]
    public void StartupFailsClosedOnMalformedMetadata()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using (var session = ChainstateSession.OpenNative(dir, chain))
                session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

            File.WriteAllText(Path.Combine(dir, "chainstate-file", "metadata.json"), "{");
            Assert.Throws<JsonException>(() => ChainstateSession.OpenNative(dir, chain));
        });
    }

    [Fact]
    public void StartupFailsClosedWhenValidatedTipExceedsBlockIndex()
    {
        WithFileBackend(() =>
        {
            var dir = TempDir();
            var chain = ChainRegistry.Get("testnet4");
            using (var session = ChainstateSession.OpenNative(dir, chain))
                session.Store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);

            File.WriteAllText(
                Path.Combine(dir, "chainstate-file", $"validated_tip_{chain.Name}.json"),
                JsonSerializer.Serialize(new { Height = 5, Hash = "bad" }));
            Assert.Throws<InvalidOperationException>(() => ChainstateSession.OpenNative(dir, chain));
        });
    }

    private static void SeedHeaders(IChainstateStore store, ChainParams chain, params int[] heights)
    {
        store.EnsureGenesis(chain.Name, Genesis.Testnet4, Genesis.Testnet4Hash);
        foreach (var height in heights)
        {
            var payload = FixtureBlock(height);
            var block = BlockDeserializer.Deserialize(payload);
            var hash = BlockHeaderCodec.BlockHashHex(block.Header);
            var prev = Hex.Encode(Hex.Reverse(block.Header.PrevBlock));
            store.InsertHeader(chain.Name, height, hash, prev, Hex.Encode(BlockHeaderCodec.Serialize(block.Header)));
            store.UpsertSyncState(chain.Name, new SyncStatePatch(height, hash, store.HeaderCount(chain.Name), "headers_current"));
        }
    }

    private static byte[] BlockHashInternal(byte[] payload) =>
        BlockHeaderCodec.BlockHash(BlockDeserializer.Deserialize(payload).Header);

    private static byte[] FixtureBlock(int height) =>
        Hex.Decode(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", $"block{height}_wire.hex")).Trim());

    private static string TempDir() =>
        Path.Combine(Path.GetTempPath(), "csbitnode-native-test-" + Guid.NewGuid());

    private static void WithFileBackend(Action action)
    {
        var previous = Environment.GetEnvironmentVariable("CSBITNODE_BACKEND");
        try
        {
            Environment.SetEnvironmentVariable("CSBITNODE_BACKEND", "file");
            action();
        }
        finally
        {
            Environment.SetEnvironmentVariable("CSBITNODE_BACKEND", previous);
        }
    }

    private sealed class FixtureBlockSource : BlockSync.IBlockSource
    {
        public byte[]? RequestBlock(byte[] blockHashInternal)
        {
            foreach (var height in new[] { 1, 2 })
            {
                var payload = FixtureBlock(height);
                if (BlockHashInternal(payload).AsSpan().SequenceEqual(blockHashInternal))
                    return payload;
            }
            return null;
        }
    }

    private sealed class WrongFixtureBlockSource : BlockSync.IBlockSource
    {
        public byte[]? RequestBlock(byte[] blockHashInternal) => FixtureBlock(2);
    }

    private sealed class CountingChainstateStore : IChainstateStore
    {
        public Dictionary<UtxoOutpoint, StoredUtxo> Utxos { get; } = new();
        public int GetUtxosCalls { get; private set; }
        public int GetUtxoCalls { get; private set; }
        public List<UtxoOutpoint> LastGetUtxosRequest { get; private set; } = [];
        public ChainstateMetadata Metadata { get; } = new("counting", "", "", "", "usable", -1, "", "");

        public int BootstrapStartHeight(string chain) => throw new NotSupportedException();
        public int GetValidatedHeight(string chain) => throw new NotSupportedException();
        public string? GetValidatedHash(string chain) => throw new NotSupportedException();
        public SyncState? GetSyncState(string chain) => throw new NotSupportedException();
        public void UpsertSyncState(string chain, SyncStatePatch patch) => throw new NotSupportedException();
        public SyncTimingSummary? GetSyncTimingSummary(string chain) => throw new NotSupportedException();
        public void SetSyncTimingSummary(string chain, SyncTimingSummary summary) => throw new NotSupportedException();
        public void EnsureGenesis(string chain, BlockHeader genesis, string genesisHash) => throw new NotSupportedException();
        public string? GetHeaderHash(string chain, int height) => throw new NotSupportedException();
        public string? GetHeaderSerializedHex(string chain, int height) => throw new NotSupportedException();
        public int HeaderCount(string chain) => throw new NotSupportedException();
        public void InsertHeader(string chain, int height, string blockHash, string prevHash, string headerHex) => throw new NotSupportedException();
        public List<byte[]> NextLocator(string chain, int bestHeight, byte[] genesisHashInternal) => throw new NotSupportedException();

        public StoredUtxo? GetUtxo(string chain, string txid, int vout)
        {
            GetUtxoCalls++;
            return Utxos.GetValueOrDefault(new UtxoOutpoint(txid, vout));
        }

        public IReadOnlyList<StoredUtxo?> GetUtxos(string chain, IReadOnlyList<UtxoOutpoint> outpoints)
        {
            GetUtxosCalls++;
            LastGetUtxosRequest = outpoints.ToList();
            return outpoints.Select(outpoint => Utxos.GetValueOrDefault(outpoint)).ToList();
        }

        public ChainstateCommitResult CommitBlock(ChainstateBlockCommit commit) => throw new NotSupportedException();
        public IReadOnlyList<UtxoUndoEntry> ReadUndo(string chain, int height) => throw new NotSupportedException();
        public long RecordBlock(string chain, int height, string blockHash, int fileNumber, int fileOffset, int blockSize) => throw new NotSupportedException();
        public ChainstateBlockIndex? GetBlock(string chain, int height) => throw new NotSupportedException();
        public long BlockCount(string chain) => throw new NotSupportedException();
        public int MaxStoredBlockHeight(string chain) => throw new NotSupportedException();
        public long UtxoCount(string chain) => throw new NotSupportedException();
        public void LogEvent(string category, string message, string severity, string? detailsJson = null) => throw new NotSupportedException();
        public void RecordBlocker(string chain, ValidationBlocker blocker) => throw new NotSupportedException();
        public string? CurrentBlockerJson(string chain) => throw new NotSupportedException();
        public long RecordPeerConnected(string host, int port, string direction, ulong services, int version, string userAgent, int startHeight) => throw new NotSupportedException();
        public void Dispose()
        {
        }
    }
}
