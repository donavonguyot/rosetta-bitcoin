using System.Text.Json;
using CsBitNode.Consensus;
using CsBitNode.Consensus.Connect;
using CsBitNode.Messages;
using CsBitNode.Sync;
using CsBitNode.Util;
using RocksDbSharp;

namespace CsBitNode.Db;

public sealed class RocksDbChainstateStore : IChainstateStore, IChainstateCommitTimingSource
{
    public const string BackendName = "rocksdb";
    public const string CodecVersion = "2";
    public const string SchemaVersion = "2";

    private readonly string _path;
    private readonly RocksDbTuning _tuning;
    private readonly RocksDb _db;
    private readonly bool _disableWal;
    private ChainstateMetadata _metadata;

    public RocksDbChainstateStore(string path, string chain)
    {
        _path = Path.GetFullPath(path);
        Directory.CreateDirectory(_path);
        _tuning = RocksDbTuning.Create();
        _disableWal = IsEnabled(Environment.GetEnvironmentVariable("CSBITNODE_ROCKSDB_DISABLE_WAL"));
        _db = RocksDb.Open(_tuning.Options, _path);
        _metadata = ReadMetadata()
            ?? new ChainstateMetadata(BackendName, _path, "rocksdb-" + Guid.NewGuid(), SchemaVersion, "usable", -1, "", UtcNowIso());
        PutMetadata("backend_name", _metadata.BackendName);
        PutMetadata("backend_path", _metadata.BackendPath);
        PutMetadata("generation_id", _metadata.GenerationId);
        PutMetadata("schema_version", _metadata.SchemaVersion);
        PutMetadata("codec_version", CodecVersion);
        PutMetadata("status", _metadata.Status);
    }

    public ChainstateMetadata Metadata => _metadata;

    public IReadOnlyDictionary<string, long> LastCommitTimingTicks { get; private set; } = new Dictionary<string, long>();

    public string? MetadataValue(string key) => GetMetadata(key);

    public int BootstrapStartHeight(string chain) => Math.Max(GetValidatedHeight(chain), 0);

    public int GetValidatedHeight(string chain) => ReadTip(chain).Height;

    public string? GetValidatedHash(string chain)
    {
        var hash = ReadTip(chain).HashHex;
        return string.IsNullOrWhiteSpace(hash) ? null : hash;
    }

    public SyncState? GetSyncState(string chain) => ReadJson<SyncState>(StatusKey("sync_state", chain));

    public void UpsertSyncState(string chain, SyncStatePatch patch)
    {
        var existing = GetSyncState(chain);
        PutJson(
            StatusKey("sync_state", chain),
            new SyncState(
                patch.BestHeight ?? existing?.BestHeight ?? 0,
                patch.BestHash ?? existing?.BestHash ?? "",
                patch.HeaderCount ?? existing?.HeaderCount ?? HeaderCount(chain),
                patch.SyncStatus ?? existing?.SyncStatus ?? "starting"));
    }

    public SyncTimingSummary? GetSyncTimingSummary(string chain) => ReadJson<SyncTimingSummary>(StatusKey("sync_timing", chain));

    public void SetSyncTimingSummary(string chain, SyncTimingSummary summary) =>
        PutJson(StatusKey("sync_timing", chain), summary);

    public void EnsureGenesis(string chain, BlockHeader genesis, string genesisHash)
    {
        if (GetHeaderHash(chain, 0) is null)
        {
            InsertHeader(chain, 0, genesisHash, "", Hex.Encode(BlockHeaderCodec.Serialize(genesis)));
            UpsertSyncState(chain, new SyncStatePatch(0, genesisHash, 1, "starting"));
            SetValidatedTip(chain, 0, genesisHash);
        }
    }

    public string? GetHeaderHash(string chain, int height)
    {
        var value = _db.Get(ChainstateCodecV2.HeaderKey(chain, height));
        if (value is null)
            return null;
        var header = ChainstateCodecV2.DecodeHeader(value);
        var offset = 0;
        return BlockHeaderCodec.BlockHashHex(BlockHeaderCodec.Deserialize(header, ref offset));
    }

    public string? GetHeaderSerializedHex(string chain, int height)
    {
        var value = _db.Get(ChainstateCodecV2.HeaderKey(chain, height));
        return value is null ? null : Hex.Encode(ChainstateCodecV2.DecodeHeader(value));
    }

    public int HeaderCount(string chain) => (int)MaintainedCounter("header_count", chain, () => CountPrefix(ChainstateCodecV2.HeaderKey(chain, 0)[..^4]));

    public void InsertHeader(string chain, int height, string blockHash, string prevHash, string headerHex)
    {
        var key = ChainstateCodecV2.HeaderKey(chain, height);
        var isNew = _db.Get(key) is null;
        _db.Put(key, ChainstateCodecV2.EncodeHeader(Hex.Decode(headerHex)));
        if (isNew)
            BumpCounterIfPresent("header_count", chain, 1);
    }

    public List<byte[]> NextLocator(string chain, int bestHeight, byte[] genesisHashInternal)
    {
        var locator = new List<byte[]>();
        var step = 1;
        var height = bestHeight;
        while (height >= 0)
        {
            var hashHex = GetHeaderHash(chain, height);
            if (hashHex is null)
                break;
            locator.Add(Hex.Reverse(Hex.Decode(hashHex)));
            if (height == 0)
                break;
            height -= step;
            if (height < 0)
                break;
            step *= 2;
        }
        if (locator.Count == 0)
            locator.Add(genesisHashInternal);
        return locator;
    }

    public StoredUtxo? GetUtxo(string chain, string txid, int vout)
    {
        var value = _db.Get(ChainstateCodecV2.UtxoKey(chain, txid, vout));
        return value is null ? null : ChainstateCodecV2.DecodeUtxo(txid, vout, value);
    }

    public IReadOnlyList<StoredUtxo?> GetUtxos(string chain, IReadOnlyList<UtxoOutpoint> outpoints)
    {
        if (outpoints.Count == 0)
            return [];

        var keys = new byte[outpoints.Count][];
        for (var i = 0; i < outpoints.Count; i++)
            keys[i] = ChainstateCodecV2.UtxoKey(chain, outpoints[i].Txid, outpoints[i].Vout);

        var values = _db.MultiGet(keys, null!, null!);
        var result = new List<StoredUtxo?>(outpoints.Count);
        for (var i = 0; i < outpoints.Count; i++)
        {
            var value = values[i].Value;
            result.Add(value is null ? null : ChainstateCodecV2.DecodeUtxo(outpoints[i].Txid, outpoints[i].Vout, value));
        }
        return result;
    }

    public ChainstateCommitResult CommitBlock(ChainstateBlockCommit commit)
    {
        var commitStarted = System.Diagnostics.Stopwatch.StartNew();
        var timings = new Dictionary<string, long>(StringComparer.Ordinal);
        var updatedAt = UtcNowIso();
        var metadata = _metadata with { TipHeight = commit.Height, TipHash = commit.BlockHashHex, UpdatedAt = updatedAt };
        using var batch = new WriteBatch();
        var stageStarted = System.Diagnostics.Stopwatch.StartNew();
        foreach (var outpoint in commit.SpentOutpoints)
            batch.Delete(ChainstateCodecV2.UtxoKey(commit.Chain, outpoint.Txid, outpoint.Vout));
        stageStarted.Stop();
        timings["utxo_delete_prepare"] = stageStarted.ElapsedTicks;
        stageStarted.Restart();
        foreach (var utxo in commit.CreatedUtxos)
            batch.Put(ChainstateCodecV2.UtxoKey(commit.Chain, utxo.Txid, utxo.Vout), ChainstateCodecV2.EncodeUtxo(utxo));
        stageStarted.Stop();
        timings["utxo_put_prepare"] = stageStarted.ElapsedTicks;
        stageStarted.Restart();
        batch.Put(ChainstateCodecV2.UndoKey(commit.Chain, commit.Height), ChainstateCodecV2.EncodeUndo(commit.UndoEntries));
        stageStarted.Stop();
        timings["undo_put_prepare"] = stageStarted.ElapsedTicks;
        stageStarted.Restart();
        if (commit.StoredBlock is not null)
        {
            var blockKey = ChainstateCodecV2.BlockIndexKey(commit.Chain, commit.Height);
            var blockIndexIsNew = _db.Get(blockKey) is null;
            batch.Put(
                blockKey,
                ChainstateCodecV2.EncodeBlockIndex(
                    commit.BlockHashHex,
                    commit.StoredBlock.FileNumber,
                    commit.StoredBlock.FileOffset,
                    commit.StoredBlock.BlockSize));
            if (blockIndexIsNew)
                PutCounterIfPresent(batch, "block_count", commit.Chain, 1);
            PutMaxCounterIfHigher(batch, "max_stored_block_height", commit.Chain, commit.Height);
        }
        batch.Put(ChainstateCodecV2.TipKey(commit.Chain), ChainstateCodecV2.EncodeTip(commit.Height, commit.BlockHashHex));
        PutMetadata(batch, "backend_name", metadata.BackendName);
        PutMetadata(batch, "backend_path", metadata.BackendPath);
        PutMetadata(batch, "generation_id", metadata.GenerationId);
        PutMetadata(batch, "schema_version", metadata.SchemaVersion);
        PutMetadata(batch, "codec_version", CodecVersion);
        PutMetadata(batch, "status", metadata.Status);
        PutMetadata(batch, "tip_height", commit.Height.ToString());
        PutMetadata(batch, "tip_hash", commit.BlockHashHex);
        PutMetadata(batch, "updated_at", updatedAt);
        PutCounterIfPresent(batch, "utxo_count", commit.Chain, commit.CreatedUtxos.Count - commit.SpentOutpoints.Count);
        stageStarted.Stop();
        timings["metadata_put_prepare"] = stageStarted.ElapsedTicks;
        stageStarted.Restart();
        _db.Write(batch, NewWriteOptions());
        stageStarted.Stop();
        timings["rocksdb_write"] = stageStarted.ElapsedTicks;
        commitStarted.Stop();
        timings["commit"] = commitStarted.ElapsedTicks;
        LastCommitTimingTicks = timings;
        _metadata = metadata;
        return new ChainstateCommitResult(commit.Height, commit.BlockHashHex, commit.CreatedUtxos.Count, commit.SpentOutpoints.Count);
    }

    public IReadOnlyList<UtxoUndoEntry> ReadUndo(string chain, int height)
    {
        var value = _db.Get(ChainstateCodecV2.UndoKey(chain, height));
        return value is null ? [] : ChainstateCodecV2.DecodeUndo(value);
    }

    public long RecordBlock(string chain, int height, string blockHash, int fileNumber, int fileOffset, int blockSize)
    {
        var key = ChainstateCodecV2.BlockIndexKey(chain, height);
        var isNew = _db.Get(key) is null;
        _db.Put(key, ChainstateCodecV2.EncodeBlockIndex(blockHash, fileNumber, fileOffset, blockSize));
        if (isNew)
            BumpCounterIfPresent("block_count", chain, 1);
        SetMaxCounterIfHigher("max_stored_block_height", chain, height);
        return height;
    }

    public ChainstateBlockIndex? GetBlock(string chain, int height)
    {
        var value = _db.Get(ChainstateCodecV2.BlockIndexKey(chain, height));
        if (value is null)
            return null;
        var decoded = ChainstateCodecV2.DecodeBlockIndex(value);
        return new ChainstateBlockIndex(chain, height, decoded.BlockHashHex, decoded.FileNumber, decoded.FileOffset, decoded.BlockSize);
    }

    public long BlockCount(string chain) => MaintainedCounter("block_count", chain, () => CountPrefix(ChainstateCodecV2.BlockIndexKey(chain, 0)[..^4]));

    public int MaxStoredBlockHeight(string chain) =>
        (int)MaintainedCounter("max_stored_block_height", chain, () => MaxHeightForPrefix(ChainstateCodecV2.BlockIndexKey(chain, 0)[..^4]));

    public long UtxoCount(string chain) => MaintainedCounter("utxo_count", chain, () => CountPrefix(ChainstateCodecV2.UtxoPrefixKey(chain)));

    public void LogEvent(string category, string message, string severity, string? detailsJson = null)
    {
        PutJson(StatusKey("event", $"{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}-{Guid.NewGuid():N}"), new
        {
            category,
            message,
            severity,
            detailsJson,
            createdAt = UtcNowIso()
        });
    }

    public void RecordBlocker(string chain, ValidationBlocker blocker) => PutJson(StatusKey("blocker", chain), blocker.ToRecord());

    public string? CurrentBlockerJson(string chain)
    {
        var value = _db.Get(StatusKey("blocker", chain));
        return value is null ? null : System.Text.Encoding.UTF8.GetString(value);
    }

    public long RecordPeerConnected(string host, int port, string direction, ulong services, int version, string userAgent, int startHeight)
    {
        LogEvent("p2p", "Peer connected", "info", $"{host}:{port}");
        return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    public void Dispose()
    {
        _db.Dispose();
        _tuning.Dispose();
    }

    private (int Height, string HashHex) ReadTip(string chain)
    {
        var value = _db.Get(ChainstateCodecV2.TipKey(chain));
        return value is null ? (-1, "") : ChainstateCodecV2.DecodeTip(value);
    }

    private void SetValidatedTip(string chain, int height, string hash)
    {
        _db.Put(ChainstateCodecV2.TipKey(chain), ChainstateCodecV2.EncodeTip(height, hash));
        _metadata = _metadata with { TipHeight = height, TipHash = hash, UpdatedAt = UtcNowIso() };
    }

    private ChainstateMetadata? ReadMetadata()
    {
        var backend = GetMetadata("backend_name");
        if (backend is null)
            return null;
        return new ChainstateMetadata(
            backend,
            GetMetadata("backend_path") ?? _path,
            GetMetadata("generation_id") ?? "rocksdb-unknown",
            GetMetadata("schema_version") ?? SchemaVersion,
            GetMetadata("status") ?? "usable",
            int.TryParse(GetMetadata("tip_height"), out var tipHeight) ? tipHeight : -1,
            GetMetadata("tip_hash") ?? "",
            GetMetadata("updated_at") ?? UtcNowIso());
    }

    private string? GetMetadata(string key)
    {
        var value = _db.Get(ChainstateCodecV2.MetadataKey(key));
        return value is null ? null : ChainstateCodecV2.DecodeMetadataValue(value);
    }

    private void PutMetadata(string key, string value) =>
        _db.Put(ChainstateCodecV2.MetadataKey(key), ChainstateCodecV2.MetadataValue(value));

    private static void PutMetadata(WriteBatch batch, string key, string value) =>
        batch.Put(ChainstateCodecV2.MetadataKey(key), ChainstateCodecV2.MetadataValue(value));

    private byte[] StatusKey(string kind, string name) => ChainstateCodecV2.MetadataKey($"{kind}:{name}");

    private T? ReadJson<T>(byte[] key)
    {
        var value = _db.Get(key);
        return value is null ? default : JsonSerializer.Deserialize<T>(value);
    }

    private void PutJson<T>(byte[] key, T value) => _db.Put(key, JsonSerializer.SerializeToUtf8Bytes(value));

    private long MaintainedCounter(string name, string chain, Func<long> scan)
    {
        var key = CounterKey(name, chain);
        var value = _db.Get(key);
        if (value is not null)
            return long.Parse(ChainstateCodecV2.DecodeMetadataValue(value), System.Globalization.CultureInfo.InvariantCulture);
        var counted = scan();
        _db.Put(key, ChainstateCodecV2.MetadataValue(counted.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return counted;
    }

    private long? ReadCounter(string name, string chain)
    {
        var value = _db.Get(CounterKey(name, chain));
        return value is null
            ? null
            : long.Parse(ChainstateCodecV2.DecodeMetadataValue(value), System.Globalization.CultureInfo.InvariantCulture);
    }

    private void BumpCounterIfPresent(string name, string chain, long delta)
    {
        var existing = ReadCounter(name, chain);
        if (existing is null)
            return;
        _db.Put(CounterKey(name, chain), ChainstateCodecV2.MetadataValue((existing.Value + delta).ToString(System.Globalization.CultureInfo.InvariantCulture)));
    }

    private void SetMaxCounterIfHigher(string name, string chain, int candidate)
    {
        var existing = ReadCounter(name, chain);
        if (existing is null || candidate <= existing.Value)
            return;
        _db.Put(CounterKey(name, chain), ChainstateCodecV2.MetadataValue(candidate.ToString(System.Globalization.CultureInfo.InvariantCulture)));
    }

    private void PutCounterIfPresent(WriteBatch batch, string name, string chain, long delta)
    {
        var existing = ReadCounter(name, chain);
        if (existing is null)
            return;
        batch.Put(CounterKey(name, chain), ChainstateCodecV2.MetadataValue((existing.Value + delta).ToString(System.Globalization.CultureInfo.InvariantCulture)));
    }

    private void PutMaxCounterIfHigher(WriteBatch batch, string name, string chain, int candidate)
    {
        var existing = ReadCounter(name, chain);
        if (existing is null || candidate <= existing.Value)
            return;
        batch.Put(CounterKey(name, chain), ChainstateCodecV2.MetadataValue(candidate.ToString(System.Globalization.CultureInfo.InvariantCulture)));
    }

    private static byte[] CounterKey(string name, string chain) => ChainstateCodecV2.MetadataKey($"counter:{name}:{chain}");

    private WriteOptions NewWriteOptions()
    {
        var options = new WriteOptions();
        if (_disableWal)
            options.DisableWal(1);
        return options;
    }

    private long CountPrefix(byte[] prefix)
    {
        long count = 0;
        using var iterator = _db.NewIterator();
        for (iterator.Seek(prefix); iterator.Valid(); iterator.Next())
        {
            if (!iterator.Key().AsSpan().StartsWith(prefix))
                break;
            count += 1;
        }
        return count;
    }

    private int MaxHeightForPrefix(byte[] prefix)
    {
        var max = 0;
        using var iterator = _db.NewIterator();
        for (iterator.Seek(prefix); iterator.Valid(); iterator.Next())
        {
            var key = iterator.Key();
            if (!key.AsSpan().StartsWith(prefix))
                break;
            var height = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(key.AsSpan(prefix.Length, 4));
            max = Math.Max(max, (int)height);
        }
        return max;
    }

    private static string UtcNowIso() => DateTimeOffset.UtcNow.ToString("O");

    private static bool IsEnabled(string? value) =>
        value is not null && (value.Trim() == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase));
}

internal sealed class RocksDbTuning
{
    private readonly IntPtr _blockCache;
    private readonly IntPtr _filterPolicy;

    private RocksDbTuning(DbOptions options, IntPtr blockCache, IntPtr filterPolicy)
    {
        Options = options;
        _blockCache = blockCache;
        _filterPolicy = filterPolicy;
    }

    public DbOptions Options { get; }

    public static RocksDbTuning Create()
    {
        var blockCache = Native.Instance.rocksdb_cache_create_lru((UIntPtr)(256L << 20));
        var filterPolicy = Native.Instance.rocksdb_filterpolicy_create_bloom(10);
        var tableOptions = new BlockBasedTableOptions()
            .SetBlockCache(blockCache)
            .SetFilterPolicy(filterPolicy)
            .SetCacheIndexAndFilterBlocks(true)
            .SetPinL0FilterAndIndexBlocksInCache(true);
        var options = new DbOptions()
            .SetCreateIfMissing(true)
            .SetBlockBasedTableFactory(tableOptions)
            .SetWriteBufferSize(64L << 20)
            .SetMaxWriteBufferNumber(4)
            .SetMaxBackgroundCompactions(4)
            .SetMaxBackgroundFlushes(2);
        return new RocksDbTuning(options, blockCache, filterPolicy);
    }

    public void Dispose()
    {
        Native.Instance.rocksdb_cache_destroy(_blockCache);
        Native.Instance.rocksdb_filterpolicy_destroy(_filterPolicy);
    }
}
