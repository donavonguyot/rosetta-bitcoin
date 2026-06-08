using CsBitNode.Chain;
using CsBitNode.Storage;

namespace CsBitNode.Db;

public sealed class ChainstateSession : IDisposable
{
    public const string NativeMarkerFileName = ".csbitnode_storage_native";

    private readonly DatadirLock _lock;

    private ChainstateSession(DatadirLock dirLock, IChainstateStore store, BlockStorage blockStorage)
    {
        _lock = dirLock;
        Store = store;
        BlockStorage = blockStorage;
    }

    public IChainstateStore Store { get; }
    public BlockStorage BlockStorage { get; }

    public static string NativeMarkerPath(string dataDir) => Path.Combine(dataDir, NativeMarkerFileName);

    public static bool IsNativeDatadir(string dataDir) => File.Exists(NativeMarkerPath(dataDir));

    // Opens RocksDB runtime truth under the datadir lock unless acquireLock is false (read-only paths).
    public static ChainstateSession OpenNative(string dataDir, ChainParams chain, bool acquireLock = true)
    {
        dataDir = Path.GetFullPath(dataDir);
        Directory.CreateDirectory(dataDir);

        var dirLock = acquireLock ? DatadirLock.Acquire(dataDir) : DatadirLock.Noop(dataDir);
        try
        {
            File.WriteAllText(NativeMarkerPath(dataDir), "native_storage=true" + Environment.NewLine);
            var backend = Environment.GetEnvironmentVariable("CSBITNODE_BACKEND")?.Trim().ToLowerInvariant();
            IChainstateStore store = backend == "file"
                ? new NativeFileChainstateStore(Path.Combine(dataDir, "chainstate-file"), chain.Name)
                : new RocksDbChainstateStore(Path.Combine(dataDir, "chainstate-rocksdb"), chain.Name);
            var blockStorage = new BlockStorage(new BlockStore(Path.Combine(dataDir, "blocks"), chain.Magic));
            VerifyInvariants(store, chain.Name);
            return new ChainstateSession(dirLock, store, blockStorage);
        }
        catch
        {
            dirLock.Dispose();
            throw;
        }
    }

    private static void VerifyInvariants(IChainstateStore store, string chain)
    {
        if (store.Metadata.Status != "usable")
            throw new InvalidOperationException($"chainstate status is {store.Metadata.Status}");
        if (store is RocksDbChainstateStore rocksDb)
        {
            if (store.Metadata.BackendName != RocksDbChainstateStore.BackendName)
                throw new InvalidOperationException($"RocksDB store metadata backend is {store.Metadata.BackendName}");
            if (store.Metadata.SchemaVersion != RocksDbChainstateStore.SchemaVersion)
                throw new InvalidOperationException($"RocksDB store schema_version is {store.Metadata.SchemaVersion}");
            if (rocksDb.MetadataValue("codec_version") != RocksDbChainstateStore.CodecVersion)
                throw new InvalidOperationException($"RocksDB store codec_version is {rocksDb.MetadataValue("codec_version")}");
            if (string.IsNullOrWhiteSpace(store.Metadata.GenerationId))
                throw new InvalidOperationException("RocksDB store generation_id is missing");
        }
        var validated = store.GetValidatedHeight(chain);
        var maxStored = store.MaxStoredBlockHeight(chain);
        if (validated > maxStored && validated > 0)
            throw new InvalidOperationException($"validated height {validated} exceeds stored block height {maxStored}");
    }

    public void Dispose()
    {
        try
        {
            Store.Dispose();
        }
        finally
        {
            _lock.Dispose();
        }
    }
}
