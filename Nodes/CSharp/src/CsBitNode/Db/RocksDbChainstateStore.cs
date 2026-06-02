using System.Text.Json;
using CsBitNode.Consensus;
using CsBitNode.Consensus.Connect;
using CsBitNode.Messages;
using CsBitNode.Util;
using RocksDbSharp;

namespace CsBitNode.Db;

public sealed class RocksDbChainstateStore : IChainstateStore
{
    public const string BackendName = "rocksdb";
    public const string CodecVersion = "2";
    public const string SchemaVersion = "2";

    private readonly string _path;
    private readonly RocksDb _db;
    private ChainstateMetadata _metadata;

    public RocksDbChainstateStore(string path, string chain)
    {
        _path = Path.GetFullPath(path);
        Directory.CreateDirectory(_path);
        var options = new DbOptions().SetCreateIfMissing(true);
        _db = RocksDb.Open(options, _path);
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

    public int HeaderCount(string chain) => (int)CountPrefix(ChainstateCodecV2.HeaderKey(chain, 0)[..^4]);

    public void InsertHeader(string chain, int height, string blockHash, string prevHash, string headerHex) =>
        _db.Put(ChainstateCodecV2.HeaderKey(chain, height), ChainstateCodecV2.EncodeHeader(Hex.Decode(headerHex)));

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

    public ChainstateCommitResult CommitBlock(ChainstateBlockCommit commit)
    {
        using var batch = new WriteBatch();
        foreach (var outpoint in commit.SpentOutpoints)
            batch.Delete(ChainstateCodecV2.UtxoKey(commit.Chain, outpoint.Txid, outpoint.Vout));
        foreach (var utxo in commit.CreatedUtxos)
            batch.Put(ChainstateCodecV2.UtxoKey(commit.Chain, utxo.Txid, utxo.Vout), ChainstateCodecV2.EncodeUtxo(utxo));
        batch.Put(ChainstateCodecV2.UndoKey(commit.Chain, commit.Height), ChainstateCodecV2.EncodeUndo(commit.UndoEntries));
        batch.Put(ChainstateCodecV2.TipKey(commit.Chain), ChainstateCodecV2.EncodeTip(commit.Height, commit.BlockHashHex));
        _db.Write(batch);
        _metadata = _metadata with { TipHeight = commit.Height, TipHash = commit.BlockHashHex, UpdatedAt = UtcNowIso() };
        PutMetadata("tip_height", commit.Height.ToString());
        PutMetadata("tip_hash", commit.BlockHashHex);
        PutMetadata("updated_at", _metadata.UpdatedAt);
        return new ChainstateCommitResult(commit.Height, commit.BlockHashHex, commit.CreatedUtxos.Count, commit.SpentOutpoints.Count);
    }

    public IReadOnlyList<UtxoUndoEntry> ReadUndo(string chain, int height)
    {
        var value = _db.Get(ChainstateCodecV2.UndoKey(chain, height));
        return value is null ? [] : ChainstateCodecV2.DecodeUndo(value);
    }

    public long RecordBlock(string chain, int height, string blockHash, int fileNumber, int fileOffset, int blockSize)
    {
        _db.Put(
            ChainstateCodecV2.BlockIndexKey(chain, height),
            ChainstateCodecV2.EncodeBlockIndex(blockHash, fileNumber, fileOffset, blockSize));
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

    public long BlockCount(string chain) => CountPrefix(ChainstateCodecV2.BlockIndexKey(chain, 0)[..^4]);

    public int MaxStoredBlockHeight(string chain) => MaxHeightForPrefix(ChainstateCodecV2.BlockIndexKey(chain, 0)[..^4]);

    public long UtxoCount(string chain) => CountPrefix(ChainstateCodecV2.UtxoPrefixKey(chain));

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

    public void Dispose() => _db.Dispose();

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

    private byte[] StatusKey(string kind, string name) => ChainstateCodecV2.MetadataKey($"{kind}:{name}");

    private T? ReadJson<T>(byte[] key)
    {
        var value = _db.Get(key);
        return value is null ? default : JsonSerializer.Deserialize<T>(value);
    }

    private void PutJson<T>(byte[] key, T value) => _db.Put(key, JsonSerializer.SerializeToUtf8Bytes(value));

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
}
