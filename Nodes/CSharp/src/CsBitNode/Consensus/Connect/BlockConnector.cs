using System.Buffers.Binary;
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
        byte[] expectedHashInternal,
        Action<string, int, long>? timingSink = null,
        int? expectedValidatedHeight = null,
        ChainstateBlockStorageIndex? storedBlock = null,
        bool parallelScriptRunner = false)
    {
        var validated = expectedValidatedHeight ?? store.GetValidatedHeight(chain);
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
        var txids = block.Transactions.Select(MerkleComputer.TransactionTxid).ToList();
        var sameBlockOutputs = SameBlockOutputs(block, txids);
        var view = new BlockUtxoView(store, chain, height, sameBlockOutputs);
        var prevoutLoadStarted = System.Diagnostics.Stopwatch.StartNew();
        view.PrefetchExternal(block.Transactions
            .Where(transaction => !transaction.IsCoinbase)
            .SelectMany(transaction => transaction.Inputs.Select(input => input.PreviousOutput))
            .ToList());
        prevoutLoadStarted.Stop();
        timingSink?.Invoke("utxo_load", height, prevoutLoadStarted.ElapsedTicks);

        long scriptVerifyElapsed = 0;
        for (var transactionIndex = 0; transactionIndex < block.Transactions.Count; transactionIndex++)
        {
            var transaction = block.Transactions[transactionIndex];
            if (transaction.IsCoinbase)
                continue;
            var txid = txids[transactionIndex];
            var txidHex = Hex.Encode(Hex.Reverse(txid));
            scriptVerifyElapsed += ValidateNonCoinbaseTransaction(view, blockHashHex, height, txidHex, transaction, parallelScriptRunner);
            for (var vout = 0; vout < transaction.Outputs.Count; vout++)
            {
                var output = transaction.Outputs[vout];
                if (!IsSpendableOutput(output.ScriptPubKey))
                    continue;
                view.Create(txid, vout, output.Value, output.ScriptPubKey, coinbase: false);
            }
        }
        timingSink?.Invoke("script_verify", height, scriptVerifyElapsed);

        var coinbase = block.Transactions[0];
        var coinbaseTxid = txids[0];
        for (var vout = 0; vout < coinbase.Outputs.Count; vout++)
        {
            var output = coinbase.Outputs[vout];
            if (!IsSpendableOutput(output.ScriptPubKey))
                continue;
            view.Create(coinbaseTxid, vout, output.Value, output.ScriptPubKey, coinbase: true);
        }

        var applyStarted = System.Diagnostics.Stopwatch.StartNew();
        var undoEntries = view.ExternalSpendUndoEntries();
        var commit = view.ToCommit(blockHashHex, undoEntries, storedBlock);
        applyStarted.Stop();
        timingSink?.Invoke("utxo_apply", height, applyStarted.ElapsedTicks);
        var commitStarted = System.Diagnostics.Stopwatch.StartNew();
        store.CommitBlock(commit);
        commitStarted.Stop();
        timingSink?.Invoke("commit", height, commitStarted.ElapsedTicks);
        return new ConnectResult(height, blockHashHex, view.CreatedCount);
    }

    public static bool IsSpendableOutput(byte[] scriptPubKey) =>
        scriptPubKey.Length > 0 && scriptPubKey[0] != 0x6a;

    private static HashSet<ViewOutpoint> SameBlockOutputs(Block.Block block, IReadOnlyList<byte[]> txids)
    {
        var outputs = new HashSet<ViewOutpoint>();
        for (var transactionIndex = 0; transactionIndex < block.Transactions.Count; transactionIndex++)
        {
            var transaction = block.Transactions[transactionIndex];
            for (var vout = 0; vout < transaction.Outputs.Count; vout++)
            {
                if (IsSpendableOutput(transaction.Outputs[vout].ScriptPubKey))
                    outputs.Add(ViewOutpoint.FromInternal(txids[transactionIndex], vout));
            }
        }
        return outputs;
    }

    private static long ValidateNonCoinbaseTransaction(
        BlockUtxoView view,
        string blockHashHex,
        int height,
        string txidHex,
        Transaction transaction,
        bool parallelScriptRunner)
    {
        var seen = new HashSet<ViewOutpoint>();
        var utxoInfos = new List<ViewUtxo>();
        foreach (var input in transaction.Inputs)
        {
            var lookup = ViewOutpoint.FromOutPoint(input.PreviousOutput);
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
            .Select(u => new ScriptVerify.SpentPrevout(u.ValueSats, u.ScriptPubKey))
            .ToList();

        long inputTotal = 0;
        var scriptStarted = System.Diagnostics.Stopwatch.StartNew();
        if (parallelScriptRunner && transaction.Inputs.Count > 1)
        {
            var errors = new Exception?[transaction.Inputs.Count];
            Parallel.For(0, transaction.Inputs.Count, inputIndex =>
            {
                var utxo = utxoInfos[inputIndex];
                try
                {
                    ScriptVerify.VerifyTransactionInput(
                        transaction,
                        inputIndex,
                        new ScriptVerify.VerifyInputOptions(utxo.ScriptPubKey, utxo.ValueSats, spentPrevouts));
                }
                catch (Exception error) when (error is UnsupportedScriptRule or ScriptVerifyError)
                {
                    errors[inputIndex] = error;
                }
            });
            for (var inputIndex = 0; inputIndex < errors.Length; inputIndex++)
            {
                if (errors[inputIndex] is null)
                    continue;
                ThrowScriptFailure(errors[inputIndex]!, height, blockHashHex, txidHex, inputIndex, utxoInfos[inputIndex].ScriptPubKey);
            }
        }
        else
        {
            for (var inputIndex = 0; inputIndex < transaction.Inputs.Count; inputIndex++)
            {
                var utxo = utxoInfos[inputIndex];
                try
                {
                    ScriptVerify.VerifyTransactionInput(
                        transaction,
                        inputIndex,
                        new ScriptVerify.VerifyInputOptions(utxo.ScriptPubKey, utxo.ValueSats, spentPrevouts));
                }
                catch (Exception error) when (error is UnsupportedScriptRule or ScriptVerifyError)
                {
                    ThrowScriptFailure(error, height, blockHashHex, txidHex, inputIndex, utxo.ScriptPubKey);
                }
            }
        }
        for (var inputIndex = 0; inputIndex < transaction.Inputs.Count; inputIndex++)
        {
            var utxo = utxoInfos[inputIndex];
            inputTotal += utxo.ValueSats;
        }
        scriptStarted.Stop();

        long outputTotal = transaction.Outputs.Sum(o => o.Value);
        if (inputTotal < outputTotal)
            throw new ConnectBlockException("transaction outputs exceed inputs");

        foreach (var input in transaction.Inputs)
            view.Spend(input.PreviousOutput);
        return scriptStarted.ElapsedTicks;
    }

    private static void ThrowScriptFailure(
        Exception error,
        int height,
        string blockHashHex,
        string txidHex,
        int inputIndex,
        byte[] scriptPubKey)
    {
        if (error is UnsupportedScriptRule unsupported)
            throw new ValidationBlocker(height, blockHashHex, txidHex, inputIndex, Hex.Encode(scriptPubKey), unsupported.Message, unsupported.Rule);
        if (error is ScriptVerifyError verifyError)
        {
            if (verifyError.Message.Contains("unsupported scriptPubKey template", StringComparison.Ordinal))
                throw ValidationBlocker.FromUnsupportedTemplate(height, blockHashHex, txidHex, inputIndex, scriptPubKey);
            throw new ValidationBlocker(height, blockHashHex, txidHex, inputIndex, Hex.Encode(scriptPubKey), verifyError.Message, "script_verification_failed");
        }
    }
}

internal sealed class BlockUtxoView
{
    private readonly IChainstateStore _store;
    private readonly string _chain;
    private readonly int _height;
    private readonly HashSet<ViewOutpoint> _sameBlockOutputs;
    private readonly Dictionary<ViewOutpoint, ViewUtxo> _created = new();
    private readonly Dictionary<ViewOutpoint, ViewUtxo> _loaded = new();
    private readonly HashSet<ViewOutpoint> _spent = new();
    private readonly List<UtxoUndoEntry> _externalUndo = new();
    private readonly List<UtxoOutpoint> _externalSpent = new();
    private int _createdCount;

    public BlockUtxoView(IChainstateStore store, string chain, int height, HashSet<ViewOutpoint>? sameBlockOutputs = null)
    {
        _store = store;
        _chain = chain;
        _height = height;
        _sameBlockOutputs = sameBlockOutputs ?? [];
    }

    public int CreatedCount => _createdCount;

    public void PrefetchExternal(IReadOnlyList<OutPoint> prevouts)
    {
        if (prevouts.Count == 0)
            return;
        var distinct = new Dictionary<ViewOutpoint, UtxoOutpoint>();
        foreach (var outpoint in prevouts)
        {
            var key = ViewOutpoint.FromOutPoint(outpoint);
            if (_sameBlockOutputs.Contains(key) || _created.ContainsKey(key) || _loaded.ContainsKey(key) || distinct.ContainsKey(key))
                continue;
            distinct[key] = key.ToUtxoOutpoint();
        }
        if (distinct.Count == 0)
            return;
        var keys = distinct.Keys.ToList();
        var values = _store.GetUtxos(_chain, distinct.Values.ToList());
        for (var i = 0; i < keys.Count; i++)
        {
            if (values[i] is not null)
                _loaded[keys[i]] = ViewUtxo.FromStored(values[i]!);
        }
    }

    public ViewUtxo? Get(OutPoint outpoint)
    {
        var key = ViewOutpoint.FromOutPoint(outpoint);
        if (_spent.Contains(key))
            return null;
        if (_created.TryGetValue(key, out var created))
            return created;
        if (_loaded.TryGetValue(key, out var loaded))
            return loaded;
        if (_sameBlockOutputs.Contains(key))
            return null;
        var stored = _store.GetUtxo(_chain, key.TxidHex(), key.Vout);
        if (stored is null)
            return null;
        loaded = ViewUtxo.FromStored(stored);
        _loaded[key] = loaded;
        return loaded;
    }

    public void Create(byte[] txidInternal, int vout, long value, byte[] scriptPubKey, bool coinbase)
    {
        var key = ViewOutpoint.FromInternal(txidInternal, vout);
        _created[key] = new ViewUtxo(key, _height, value, scriptPubKey.ToArray(), coinbase);
        _createdCount++;
    }

    public void Spend(OutPoint outpoint)
    {
        var key = ViewOutpoint.FromOutPoint(outpoint);
        var utxo = Get(outpoint) ?? throw new ConnectBlockException($"missing UTXO to spend {key}");
        if (!_created.ContainsKey(key))
        {
            _externalUndo.Add(new UtxoUndoEntry(utxo.TxidHex(), utxo.Vout, utxo.Height, utxo.ValueSats, Hex.Encode(utxo.ScriptPubKey), utxo.Coinbase));
            _externalSpent.Add(utxo.Outpoint.ToUtxoOutpoint());
        }
        _spent.Add(key);
        _created.Remove(key);
    }

    public IReadOnlyList<UtxoUndoEntry> ExternalSpendUndoEntries() => _externalUndo;

    public ChainstateBlockCommit ToCommit(string blockHashHex, IReadOnlyList<UtxoUndoEntry> undoEntries, ChainstateBlockStorageIndex? storedBlock = null)
    {
        return new ChainstateBlockCommit(_chain, _height, blockHashHex, _externalSpent, _created.Values.Select(utxo => utxo.ToStored()).ToList(), undoEntries, storedBlock);
    }
}

internal sealed record ViewUtxo(ViewOutpoint Outpoint, int Height, long ValueSats, byte[] ScriptPubKey, bool Coinbase)
{
    public int Vout => Outpoint.Vout;

    public static ViewUtxo FromStored(StoredUtxo stored) =>
        new(ViewOutpoint.FromTxidHex(stored.Txid, stored.Vout), stored.Height, stored.ValueSats, Hex.Decode(stored.ScriptPubKeyHex), stored.Coinbase);

    public StoredUtxo ToStored() =>
        new(TxidHex(), Vout, Height, ValueSats, Hex.Encode(ScriptPubKey), Coinbase);

    public string TxidHex() => Outpoint.TxidHex();
}

internal readonly struct ViewOutpoint : IEquatable<ViewOutpoint>
{
    private readonly ulong _a;
    private readonly ulong _b;
    private readonly ulong _c;
    private readonly ulong _d;

    private ViewOutpoint(ulong a, ulong b, ulong c, ulong d, int vout)
    {
        _a = a;
        _b = b;
        _c = c;
        _d = d;
        Vout = vout;
    }

    public int Vout { get; }

    public static ViewOutpoint FromOutPoint(OutPoint outpoint) =>
        FromInternal(outpoint.Hash, (int)outpoint.Index);

    public static ViewOutpoint FromTxidHex(string txidHex, int vout) =>
        FromInternal(Hex.Reverse(Hex.Decode(txidHex)), vout);

    public static ViewOutpoint FromInternal(byte[] txidInternal, int vout)
    {
        if (txidInternal.Length != 32)
            throw new ArgumentException("txid must be 32 bytes", nameof(txidInternal));
        return new ViewOutpoint(
            BinaryPrimitives.ReadUInt64LittleEndian(txidInternal.AsSpan(0, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(txidInternal.AsSpan(8, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(txidInternal.AsSpan(16, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(txidInternal.AsSpan(24, 8)),
            vout);
    }

    public string TxidHex()
    {
        var bytes = InternalBytes();
        return Hex.Encode(Hex.Reverse(bytes));
    }

    public UtxoOutpoint ToUtxoOutpoint() => new(TxidHex(), Vout);

    public string ToDisplayString() => $"{TxidHex()}:{Vout}";

    public bool Equals(ViewOutpoint other) =>
        _a == other._a && _b == other._b && _c == other._c && _d == other._d && Vout == other.Vout;

    public override bool Equals(object? obj) => obj is ViewOutpoint other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(_a, _b, _c, _d, Vout);

    public override string ToString() => ToDisplayString();

    private byte[] InternalBytes()
    {
        var bytes = new byte[32];
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(0, 8), _a);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(8, 8), _b);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(16, 8), _c);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(24, 8), _d);
        return bytes;
    }
}
