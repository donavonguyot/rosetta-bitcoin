namespace CsBitNode.Db;

public sealed record SyncState(int BestHeight, string BestHash, int HeaderCount, string SyncStatus);

public sealed record SyncStatePatch(int? BestHeight, string? BestHash, int? HeaderCount, string? SyncStatus);

public sealed record StoredUtxo(string Txid, int Vout, int Height, long ValueSats, string ScriptPubKeyHex, bool Coinbase);

public sealed record UtxoUndoEntry(string Txid, int Vout, int Height, long ValueSats, string ScriptPubKeyHex, bool Coinbase)
{
    public UtxoUndoEntry(string txid, int vout, long valueSats, string scriptPubKeyHex, bool coinbase)
        : this(txid, vout, 0, valueSats, scriptPubKeyHex, coinbase)
    {
    }
}

public sealed record UtxoOutpoint(string Txid, int Vout);
