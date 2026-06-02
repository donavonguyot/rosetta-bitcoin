using CsBitNode.Consensus.Merkle;
using CsBitNode.Consensus.Script;
using CsBitNode.Consensus.Tx;
using CsBitNode.Db;
using CsBitNode.Messages;
using CsBitNode.Util;

namespace CsBitNode.Consensus.Connect;

public static class BlockConnector
{
    public sealed record ConnectResult(int Height, string BlockHashHex, int UtxosCreated);

    public static ConnectResult Connect(
        IChainstateStore store,
        string chain,
        int height,
        byte[] payload,
        byte[] expectedPrevInternal,
        byte[] expectedHashInternal)
    {
        var validated = store.GetValidatedHeight(chain);
        if (height != validated + 1)
            throw new ConnectBlockException($"cannot connect height {height} on top of validated tip {validated}");

        Block.Block block;
        try
        {
            block = BlockValidator.ValidateBlock(payload, new BlockValidator.ValidateOptions(expectedPrevInternal, expectedHashInternal));
        }
        catch (BlockValidationException error)
        {
            throw new ConnectBlockException(error.Message, error);
        }

        var blockHashHex = BlockHeaderCodec.BlockHashHex(block.Header);
        var view = new BlockUtxoView(store, chain, height);

        foreach (var transaction in block.Transactions)
        {
            if (transaction.IsCoinbase)
                continue;
            var txid = MerkleComputer.TransactionTxid(transaction);
            var txidHex = Hex.Encode(Hex.Reverse(txid));
            ValidateNonCoinbaseTransaction(view, blockHashHex, height, txidHex, transaction);
            for (var vout = 0; vout < transaction.Outputs.Count; vout++)
            {
                var output = transaction.Outputs[vout];
                if (!IsSpendableOutput(output.ScriptPubKey))
                    continue;
                view.Create(txid, vout, output.Value, output.ScriptPubKey, coinbase: false);
            }
        }

        var coinbase = block.Transactions[0];
        var coinbaseTxid = MerkleComputer.TransactionTxid(coinbase);
        for (var vout = 0; vout < coinbase.Outputs.Count; vout++)
        {
            var output = coinbase.Outputs[vout];
            if (!IsSpendableOutput(output.ScriptPubKey))
                continue;
            view.Create(coinbaseTxid, vout, output.Value, output.ScriptPubKey, coinbase: true);
        }

        var undoEntries = view.ExternalSpendUndoEntries();
        var commit = view.ToCommit(blockHashHex, undoEntries);
        store.CommitBlock(commit);
        return new ConnectResult(height, blockHashHex, view.CreatedCount);
    }

    public static bool IsSpendableOutput(byte[] scriptPubKey) => scriptPubKey.Length > 0;

    private static void ValidateNonCoinbaseTransaction(
        BlockUtxoView view,
        string blockHashHex,
        int height,
        string txidHex,
        Transaction transaction)
    {
        var seen = new HashSet<string>();
        var utxoInfos = new List<StoredUtxo>();
        foreach (var input in transaction.Inputs)
        {
            var lookup = view.LookupKey(input.PreviousOutput);
            if (!seen.Add(lookup))
                throw new ConnectBlockException($"double spend of {lookup}");
            var utxo = view.Get(input.PreviousOutput);
            if (utxo is null)
                throw new ConnectBlockException($"missing UTXO {lookup}");
            if (utxo.Coinbase && height - utxo.Height < ConsensusConstants.CoinbaseMaturity)
                throw new ConnectBlockException($"coinbase output not mature at height {height} (created at {utxo.Height})");
            utxoInfos.Add(utxo);
        }

        var spentPrevouts = utxoInfos
            .Select(u => new ScriptVerify.SpentPrevout(u.ValueSats, Hex.Decode(u.ScriptPubKeyHex)))
            .ToList();

        long inputTotal = 0;
        for (var inputIndex = 0; inputIndex < transaction.Inputs.Count; inputIndex++)
        {
            var utxo = utxoInfos[inputIndex];
            var scriptPubKey = Hex.Decode(utxo.ScriptPubKeyHex);
            try
            {
                ScriptVerify.VerifyTransactionInput(
                    transaction,
                    inputIndex,
                    new ScriptVerify.VerifyInputOptions(scriptPubKey, utxo.ValueSats, spentPrevouts));
            }
            catch (UnsupportedScriptRule error)
            {
                throw new ValidationBlocker(height, blockHashHex, txidHex, inputIndex, utxo.ScriptPubKeyHex, error.Message, error.Rule);
            }
            catch (ScriptVerifyError error)
            {
                if (error.Message.Contains("unsupported scriptPubKey template", StringComparison.Ordinal))
                {
                    throw ValidationBlocker.FromUnsupportedTemplate(height, blockHashHex, txidHex, inputIndex, scriptPubKey);
                }
                throw new ValidationBlocker(height, blockHashHex, txidHex, inputIndex, utxo.ScriptPubKeyHex, error.Message, "script_verification_failed");
            }
            inputTotal += utxo.ValueSats;
        }

        long outputTotal = transaction.Outputs.Sum(o => o.Value);
        if (inputTotal < outputTotal)
            throw new ConnectBlockException("transaction outputs exceed inputs");

        foreach (var input in transaction.Inputs)
            view.Spend(input.PreviousOutput);
    }
}

internal sealed class BlockUtxoView
{
    private readonly IChainstateStore _store;
    private readonly string _chain;
    private readonly int _height;
    private readonly Dictionary<string, StoredUtxo> _overlay = new();
    private readonly HashSet<string> _spent = new();
    private readonly List<UtxoUndoEntry> _externalUndo = new();
    private readonly List<UtxoOutpoint> _externalSpent = new();
    private int _created;

    public BlockUtxoView(IChainstateStore store, string chain, int height)
    {
        _store = store;
        _chain = chain;
        _height = height;
    }

    public int CreatedCount => _created;

    public string LookupKey(OutPoint outpoint) =>
        $"{Hex.Encode(Hex.Reverse(outpoint.Hash))}:{outpoint.Index}";

    public StoredUtxo? Get(OutPoint outpoint)
    {
        var key = LookupKey(outpoint);
        if (_spent.Contains(key))
            return null;
        if (_overlay.TryGetValue(key, out var overlay))
            return overlay;
        return _store.GetUtxo(_chain, Hex.Encode(Hex.Reverse(outpoint.Hash)), (int)outpoint.Index);
    }

    public void Create(byte[] txidInternal, int vout, long value, byte[] scriptPubKey, bool coinbase)
    {
        var txidHex = Hex.Encode(Hex.Reverse(txidInternal));
        var key = $"{txidHex}:{vout}";
        _overlay[key] = new StoredUtxo(txidHex, vout, _height, value, Hex.Encode(scriptPubKey), coinbase);
        _created++;
    }

    public void Spend(OutPoint outpoint)
    {
        var key = LookupKey(outpoint);
        var utxo = Get(outpoint) ?? throw new ConnectBlockException($"missing UTXO to spend {key}");
        if (!_overlay.ContainsKey(key))
        {
            _externalUndo.Add(new UtxoUndoEntry(utxo.Txid, utxo.Vout, utxo.Height, utxo.ValueSats, utxo.ScriptPubKeyHex, utxo.Coinbase));
            _externalSpent.Add(new UtxoOutpoint(utxo.Txid, utxo.Vout));
        }
        _spent.Add(key);
        _overlay.Remove(key);
    }

    public IReadOnlyList<UtxoUndoEntry> ExternalSpendUndoEntries() => _externalUndo;

    public ChainstateBlockCommit ToCommit(string blockHashHex, IReadOnlyList<UtxoUndoEntry> undoEntries)
    {
        return new ChainstateBlockCommit(_chain, _height, blockHashHex, _externalSpent, _overlay.Values.ToList(), undoEntries);
    }
}
