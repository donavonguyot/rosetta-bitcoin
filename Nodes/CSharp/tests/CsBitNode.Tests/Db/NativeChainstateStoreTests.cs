using CsBitNode.Chain;
using CsBitNode.Consensus.Block;
using CsBitNode.Consensus.Connect;
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
}
