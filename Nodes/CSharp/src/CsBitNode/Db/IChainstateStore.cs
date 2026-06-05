using CsBitNode.Consensus;
using CsBitNode.Consensus.Connect;
using CsBitNode.Sync;

namespace CsBitNode.Db;

public interface IChainstateStore : IDisposable
{
    ChainstateMetadata Metadata { get; }

    int BootstrapStartHeight(string chain);
    int GetValidatedHeight(string chain);
    string? GetValidatedHash(string chain);
    SyncState? GetSyncState(string chain);
    void UpsertSyncState(string chain, SyncStatePatch patch);
    SyncTimingSummary? GetSyncTimingSummary(string chain);
    void SetSyncTimingSummary(string chain, SyncTimingSummary summary);

    void EnsureGenesis(string chain, BlockHeader genesis, string genesisHash);
    string? GetHeaderHash(string chain, int height);
    string? GetHeaderSerializedHex(string chain, int height);
    int HeaderCount(string chain);
    void InsertHeader(string chain, int height, string blockHash, string prevHash, string headerHex);
    List<byte[]> NextLocator(string chain, int bestHeight, byte[] genesisHashInternal);

    StoredUtxo? GetUtxo(string chain, string txid, int vout);
    IReadOnlyList<StoredUtxo?> GetUtxos(string chain, IReadOnlyList<UtxoOutpoint> outpoints);
    ChainstateCommitResult CommitBlock(ChainstateBlockCommit commit);
    IReadOnlyList<UtxoUndoEntry> ReadUndo(string chain, int height);

    long RecordBlock(string chain, int height, string blockHash, int fileNumber, int fileOffset, int blockSize);
    ChainstateBlockIndex? GetBlock(string chain, int height);
    long BlockCount(string chain);
    int MaxStoredBlockHeight(string chain);
    long UtxoCount(string chain);

    void LogEvent(string category, string message, string severity, string? detailsJson = null);
    void RecordBlocker(string chain, ValidationBlocker blocker);
    string? CurrentBlockerJson(string chain);
    long RecordPeerConnected(string host, int port, string direction, ulong services, int version, string userAgent, int startHeight);
}

public interface IChainstateCommitTimingSource
{
    IReadOnlyDictionary<string, long> LastCommitTimingTicks { get; }
}

public sealed record ChainstateMetadata(
    string BackendName,
    string BackendPath,
    string GenerationId,
    string SchemaVersion,
    string Status,
    int TipHeight,
    string TipHash,
    string UpdatedAt);

public sealed record ChainstateStats(long UtxoCount, long BlockCount);

public sealed record ChainstateCommitResult(int Height, string BlockHashHex, int Created, int Spent);

public sealed record ChainstateBlockIndex(
    string Chain,
    int Height,
    string BlockHash,
    int FileNumber,
    int FileOffset,
    int BlockSize);

public sealed record ChainstateBlockStorageIndex(int FileNumber, int FileOffset, int BlockSize);

public sealed record ChainstateBlockCommit(
    string Chain,
    int Height,
    string BlockHashHex,
    IReadOnlyList<UtxoOutpoint> SpentOutpoints,
    IReadOnlyList<StoredUtxo> CreatedUtxos,
    IReadOnlyList<UtxoUndoEntry> UndoEntries,
    ChainstateBlockStorageIndex? StoredBlock = null);
