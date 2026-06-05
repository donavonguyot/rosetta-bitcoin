using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Script;

public sealed class SighashCache
{
    private byte[]? _bip143Prevouts;
    private byte[]? _bip143Sequences;
    private byte[]? _bip143OutputsAll;
    private byte[]? _taprootPrevouts;
    private byte[]? _taprootAmounts;
    private byte[]? _taprootScriptPubKeys;
    private byte[]? _taprootSequences;
    private byte[]? _taprootOutputsAll;
    private byte[]? _legacyOutputsAll;
    private readonly Dictionary<int, byte[]> _serializedOutputs = [];
    private readonly Dictionary<int, byte[]> _legacySingleOutputs = [];
    private readonly Dictionary<int, byte[]> _taprootSingleOutputHashes = [];

    public byte[] Bip143Prevouts(Transaction transaction) =>
        _bip143Prevouts ??= CryptoUtil.DoubleSha256(Concat(transaction.Inputs, input => Sighash.SerializeOutPoint(input.PreviousOutput)));

    public byte[] Bip143Sequences(Transaction transaction) =>
        _bip143Sequences ??= CryptoUtil.DoubleSha256(Concat(transaction.Inputs, input => WireSerialize.PackInt32Le((int)input.Sequence)));

    public byte[] Bip143OutputsAll(Transaction transaction) =>
        _bip143OutputsAll ??= CryptoUtil.DoubleSha256(SerializedOutputsAll(transaction));

    public byte[] LegacyOutputsAll(Transaction transaction) =>
        _legacyOutputsAll ??= SerializedOutputsAll(transaction);

    public byte[] SerializedOutput(Transaction transaction, int index)
    {
        if (!_serializedOutputs.TryGetValue(index, out var value))
        {
            value = Sighash.SerializeOutput(transaction.Outputs[index]);
            _serializedOutputs[index] = value;
        }
        return value;
    }

    public byte[] LegacySinglePlaceholderOutputs(Transaction transaction, int inputIndex)
    {
        if (_legacySingleOutputs.TryGetValue(inputIndex, out var value))
            return value;
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(inputIndex + 1));
        for (var i = 0; i < inputIndex; i++)
        {
            ms.Write(WireSerialize.PackInt64Le(-1));
            ms.Write(WireSerialize.WriteCompactSize(0));
        }
        ms.Write(SerializedOutput(transaction, inputIndex));
        value = ms.ToArray();
        _legacySingleOutputs[inputIndex] = value;
        return value;
    }

    public byte[] TaprootPrevouts(Transaction transaction) =>
        _taprootPrevouts ??= Hash160.Sha256(Concat(transaction.Inputs, input => Sighash.SerializeOutPoint(input.PreviousOutput)));

    public byte[] TaprootAmounts(IReadOnlyList<ScriptVerify.SpentPrevout> prevouts)
    {
        if (_taprootAmounts is not null)
            return _taprootAmounts;
        using var ms = new MemoryStream();
        foreach (var prevout in prevouts)
            ms.Write(WireSerialize.PackInt64Le(prevout.Amount));
        return _taprootAmounts = Hash160.Sha256(ms.ToArray());
    }

    public byte[] TaprootScriptPubKeys(IReadOnlyList<ScriptVerify.SpentPrevout> prevouts)
    {
        if (_taprootScriptPubKeys is not null)
            return _taprootScriptPubKeys;
        using var ms = new MemoryStream();
        foreach (var prevout in prevouts)
        {
            ms.Write(WireSerialize.WriteCompactSize(prevout.ScriptPubKey.Length));
            ms.Write(prevout.ScriptPubKey);
        }
        return _taprootScriptPubKeys = Hash160.Sha256(ms.ToArray());
    }

    public byte[] TaprootSequences(Transaction transaction) =>
        _taprootSequences ??= Hash160.Sha256(Concat(transaction.Inputs, input => WireSerialize.PackInt32Le((int)input.Sequence)));

    public byte[] TaprootOutputsAll(Transaction transaction) =>
        _taprootOutputsAll ??= Hash160.Sha256(SerializedOutputsAll(transaction));

    public byte[] TaprootSingleOutputHash(Transaction transaction, int index)
    {
        if (!_taprootSingleOutputHashes.TryGetValue(index, out var value))
        {
            value = Hash160.Sha256(SerializedOutput(transaction, index));
            _taprootSingleOutputHashes[index] = value;
        }
        return value;
    }

    private static byte[] SerializedOutputsAll(Transaction transaction)
    {
        using var ms = new MemoryStream();
        foreach (var output in transaction.Outputs)
            ms.Write(Sighash.SerializeOutput(output));
        return ms.ToArray();
    }

    private static byte[] Concat<T>(IEnumerable<T> values, Func<T, byte[]> serialize)
    {
        using var ms = new MemoryStream();
        foreach (var value in values)
            ms.Write(serialize(value));
        return ms.ToArray();
    }
}
