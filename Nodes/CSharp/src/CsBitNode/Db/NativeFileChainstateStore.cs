using System.Text.Json;
using CsBitNode.Consensus;
using CsBitNode.Consensus.Connect;
using CsBitNode.Messages;
using CsBitNode.Sync;
using CsBitNode.Util;

namespace CsBitNode.Db;

public sealed class NativeFileChainstateStore : IChainstateStore, IChainstateCommitTimingSource
{
    public const string BackendName = "file";
    public const string SchemaVersion = "1";

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private readonly string _root;
    private readonly string _chain;
    private ChainstateMetadata _metadata;

    public NativeFileChainstateStore(string root, string chain)
    {
        _root = Path.GetFullPath(root);
        _chain = chain;
        Directory.CreateDirectory(_root);
        Directory.CreateDirectory(HeadersDir(chain));
        Directory.CreateDirectory(BlocksDir(chain));
        Directory.CreateDirectory(UtxosDir(chain));
        Directory.CreateDirectory(UndoDir(chain));
        Directory.CreateDirectory(EventsDir());
        CleanTempFiles();
        _metadata = ReadJson<ChainstateMetadata>(MetadataPath())
            ?? new ChainstateMetadata(
                BackendName,
                _root,
                "file-" + Guid.NewGuid(),
                SchemaVersion,
                "usable",
                -1,
                "",
                UtcNowIso());
        RecoverPendingCommit();
        WriteMetadata(_metadata);
    }

    public ChainstateMetadata Metadata => _metadata;

    public IReadOnlyDictionary<string, long> LastCommitTimingTicks { get; private set; } = new Dictionary<string, long>();

    public int BootstrapStartHeight(string chain) => Math.Max(GetValidatedHeight(chain), 0);

    public int GetValidatedHeight(string chain) => ReadTip(chain).Height;

    public string? GetValidatedHash(string chain)
    {
        var hash = ReadTip(chain).Hash;
        return string.IsNullOrWhiteSpace(hash) ? null : hash;
    }

    public SyncState? GetSyncState(string chain) =>
        ReadJson<SyncState>(SyncStatePath(chain));

    public void UpsertSyncState(string chain, SyncStatePatch patch)
    {
        var existing = GetSyncState(chain);
        WriteJson(
            SyncStatePath(chain),
            new SyncState(
                patch.BestHeight ?? existing?.BestHeight ?? 0,
                patch.BestHash ?? existing?.BestHash ?? "",
                patch.HeaderCount ?? existing?.HeaderCount ?? HeaderCount(chain),
                patch.SyncStatus ?? existing?.SyncStatus ?? "starting"));
    }

    public SyncTimingSummary? GetSyncTimingSummary(string chain) =>
        ReadJson<SyncTimingSummary>(SyncTimingPath(chain));

    public void SetSyncTimingSummary(string chain, SyncTimingSummary summary) =>
        WriteJson(SyncTimingPath(chain), summary);

    public void EnsureGenesis(string chain, BlockHeader genesis, string genesisHash)
    {
        if (GetHeaderHash(chain, 0) is null)
        {
            InsertHeader(chain, 0, genesisHash, "", Hex.Encode(BlockHeaderCodec.Serialize(genesis)));
            UpsertSyncState(chain, new SyncStatePatch(0, genesisHash, 1, "starting"));
            SetValidatedTip(chain, 0, genesisHash);
        }
    }

    public string? GetHeaderHash(string chain, int height) => ReadHeader(chain, height)?.BlockHash;

    public string? GetHeaderSerializedHex(string chain, int height) =>
        ReadHeader(chain, height)?.HeaderSerializedHex;

    public int HeaderCount(string chain) => Directory.GetFiles(HeadersDir(chain), "*.json").Length;

    public void InsertHeader(string chain, int height, string blockHash, string prevHash, string headerHex) =>
        WriteJson(HeaderPath(chain, height), new HeaderRecord(chain, height, blockHash, prevHash, headerHex));

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

    public StoredUtxo? GetUtxo(string chain, string txid, int vout) =>
        ReadJson<StoredUtxo>(UtxoPath(chain, txid, vout));

    public IReadOnlyList<StoredUtxo?> GetUtxos(string chain, IReadOnlyList<UtxoOutpoint> outpoints) =>
        outpoints.Select(outpoint => GetUtxo(chain, outpoint.Txid, outpoint.Vout)).ToList();

    public ChainstateCommitResult CommitBlock(ChainstateBlockCommit commit)
    {
        var commitStarted = System.Diagnostics.Stopwatch.StartNew();
        var timings = new Dictionary<string, long>(StringComparer.Ordinal);
        var stageStarted = System.Diagnostics.Stopwatch.StartNew();
        WriteJson(CommitJournalPath(), CommitJournal.FromCommit(commit));
        stageStarted.Stop();
        timings["metadata_put_prepare"] = stageStarted.ElapsedTicks;
        stageStarted.Restart();
        ApplyCommit(commit);
        stageStarted.Stop();
        timings["rocksdb_write"] = stageStarted.ElapsedTicks;
        File.Delete(CommitJournalPath());
        timings.TryAdd("utxo_delete_prepare", 0);
        timings.TryAdd("utxo_put_prepare", 0);
        timings.TryAdd("undo_put_prepare", 0);
        commitStarted.Stop();
        timings["commit"] = commitStarted.ElapsedTicks;
        LastCommitTimingTicks = timings;
        return new ChainstateCommitResult(
            commit.Height,
            commit.BlockHashHex,
            commit.CreatedUtxos.Count,
            commit.SpentOutpoints.Count);
    }

    private void ApplyCommit(ChainstateBlockCommit commit)
    {
        foreach (var outpoint in commit.SpentOutpoints)
            File.Delete(UtxoPath(commit.Chain, outpoint.Txid, outpoint.Vout));
        foreach (var utxo in commit.CreatedUtxos)
            WriteJson(UtxoPath(commit.Chain, utxo.Txid, utxo.Vout), utxo);
        WriteJson(UndoPath(commit.Chain, commit.Height), commit.UndoEntries);
        if (commit.StoredBlock is not null)
            WriteJson(
                BlockPath(commit.Chain, commit.Height),
                new ChainstateBlockIndex(
                    commit.Chain,
                    commit.Height,
                    commit.BlockHashHex,
                    commit.StoredBlock.FileNumber,
                    commit.StoredBlock.FileOffset,
                    commit.StoredBlock.BlockSize));
        SetValidatedTip(commit.Chain, commit.Height, commit.BlockHashHex);
    }

    public IReadOnlyList<UtxoUndoEntry> ReadUndo(string chain, int height) =>
        ReadJson<List<UtxoUndoEntry>>(UndoPath(chain, height)) ?? [];

    public long RecordBlock(string chain, int height, string blockHash, int fileNumber, int fileOffset, int blockSize)
    {
        WriteJson(
            BlockPath(chain, height),
            new ChainstateBlockIndex(chain, height, blockHash, fileNumber, fileOffset, blockSize));
        return height;
    }

    public ChainstateBlockIndex? GetBlock(string chain, int height) =>
        ReadJson<ChainstateBlockIndex>(BlockPath(chain, height));

    public long BlockCount(string chain) => Directory.GetFiles(BlocksDir(chain), "*.json").LongLength;

    public int MaxStoredBlockHeight(string chain)
    {
        return Directory.GetFiles(BlocksDir(chain), "*.json")
            .Select(path => int.TryParse(Path.GetFileNameWithoutExtension(path), out var height) ? height : 0)
            .DefaultIfEmpty(0)
            .Max();
    }

    public long UtxoCount(string chain) => Directory.GetFiles(UtxosDir(chain), "*.json").LongLength;

    public void LogEvent(string category, string message, string severity, string? detailsJson = null)
    {
        var path = Path.Combine(EventsDir(), $"{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}-{Guid.NewGuid():N}.json");
        WriteJson(path, new EventRecord(category, message, severity, detailsJson, UtcNowIso()));
    }

    public void RecordBlocker(string chain, ValidationBlocker blocker) =>
        WriteJson(BlockerPath(chain), blocker.ToRecord());

    public string? CurrentBlockerJson(string chain) =>
        File.Exists(BlockerPath(chain)) ? File.ReadAllText(BlockerPath(chain)) : null;

    public long RecordPeerConnected(string host, int port, string direction, ulong services, int version, string userAgent, int startHeight)
    {
        LogEvent("p2p", "Peer connected", "info", $"{host}:{port}");
        return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    public void Dispose()
    {
    }

    private TipRecord ReadTip(string chain) => ReadJson<TipRecord>(TipPath(chain)) ?? new TipRecord(-1, "");

    private void SetValidatedTip(string chain, int height, string hash)
    {
        WriteJson(TipPath(chain), new TipRecord(height, hash));
        _metadata = _metadata with { TipHeight = height, TipHash = hash, UpdatedAt = UtcNowIso() };
        WriteMetadata(_metadata);
    }

    private HeaderRecord? ReadHeader(string chain, int height) =>
        ReadJson<HeaderRecord>(HeaderPath(chain, height));

    private void WriteMetadata(ChainstateMetadata metadata) => WriteJson(MetadataPath(), metadata);

    private void RecoverPendingCommit()
    {
        var journal = ReadJson<CommitJournal>(CommitJournalPath());
        if (journal is null)
            return;
        ApplyCommit(journal.ToCommit());
        File.Delete(CommitJournalPath());
    }

    private void CleanTempFiles()
    {
        foreach (var temp in Directory.GetFiles(_root, "*.tmp", SearchOption.AllDirectories))
            File.Delete(temp);
    }

    private string MetadataPath() => Path.Combine(_root, "metadata.json");
    private string CommitJournalPath() => Path.Combine(_root, "commit_pending.json");
    private string TipPath(string chain) => Path.Combine(_root, $"validated_tip_{chain}.json");
    private string SyncStatePath(string chain) => Path.Combine(_root, $"sync_state_{chain}.json");
    private string SyncTimingPath(string chain) => Path.Combine(_root, $"sync_timing_{chain}.json");
    private string HeadersDir(string chain) => Path.Combine(_root, "headers", chain);
    private string BlocksDir(string chain) => Path.Combine(_root, "blocks", chain);
    private string UtxosDir(string chain) => Path.Combine(_root, "utxos", chain);
    private string UndoDir(string chain) => Path.Combine(_root, "undo", chain);
    private string EventsDir() => Path.Combine(_root, "events");
    private string HeaderPath(string chain, int height) => Path.Combine(HeadersDir(chain), $"{height:D10}.json");
    private string BlockPath(string chain, int height) => Path.Combine(BlocksDir(chain), $"{height:D10}.json");
    private string UndoPath(string chain, int height) => Path.Combine(UndoDir(chain), $"{height:D10}.json");
    private string BlockerPath(string chain) => Path.Combine(_root, $"blocker_{chain}.json");
    private string UtxoPath(string chain, string txid, int vout) => Path.Combine(UtxosDir(chain), $"{txid}_{vout}.json");

    private static T? ReadJson<T>(string path)
    {
        if (!File.Exists(path))
            return default;
        return JsonSerializer.Deserialize<T>(File.ReadAllText(path), JsonOptions);
    }

    private static void WriteJson<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, JsonOptions));
        File.Move(temp, path, overwrite: true);
    }

    private static string UtcNowIso() => DateTimeOffset.UtcNow.ToString("O");

    private sealed record TipRecord(int Height, string Hash);
    private sealed record HeaderRecord(string Chain, int Height, string BlockHash, string PrevHash, string HeaderSerializedHex);
    private sealed record EventRecord(string Category, string Message, string Severity, string? DetailsJson, string CreatedAt);
    private sealed record CommitJournal(
        string Chain,
        int Height,
        string BlockHashHex,
        List<UtxoOutpoint> SpentOutpoints,
        List<StoredUtxo> CreatedUtxos,
        List<UtxoUndoEntry> UndoEntries,
        ChainstateBlockStorageIndex? StoredBlock)
    {
        public static CommitJournal FromCommit(ChainstateBlockCommit commit) =>
            new(
                commit.Chain,
                commit.Height,
                commit.BlockHashHex,
                commit.SpentOutpoints.ToList(),
                commit.CreatedUtxos.ToList(),
                commit.UndoEntries.ToList(),
                commit.StoredBlock);

        public ChainstateBlockCommit ToCommit() =>
            new(Chain, Height, BlockHashHex, SpentOutpoints, CreatedUtxos, UndoEntries, StoredBlock);
    }
}
