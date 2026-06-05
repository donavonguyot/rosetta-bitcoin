using System.Buffers.Binary;
using CsBitNode.Consensus.Tx;
using CsBitNode.Util;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Script;

public static class Sighash
{
    public static byte[] LegacySighash(
        Transaction transaction,
        int inputIndex,
        ReadOnlySpan<byte> scriptCode,
        byte sighashType = 1,
        SighashCache? cache = null)
    {
        var timingStarted = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            if (inputIndex >= transaction.Inputs.Count)
                throw new ArgumentOutOfRangeException(nameof(inputIndex));

            var baseType = sighashType & 0x1f;
            var anyoneCanPay = (sighashType & 0x80) != 0;

            if (baseType == 3 && inputIndex >= transaction.Outputs.Count)
            {
                var invalid = new byte[32];
                invalid[0] = 0x01;
                return invalid;
            }

            var inputs = anyoneCanPay
                ? new[] { transaction.Inputs[inputIndex] }
                : transaction.Inputs.ToArray();

            using var ms = new MemoryStream();
            ms.Write(WireSerialize.PackInt32Le(transaction.Version));
            ms.Write(WireSerialize.WriteCompactSize(inputs.Length));

            for (var index = 0; index < inputs.Length; index++)
            {
                var sourceIndex = anyoneCanPay ? inputIndex : index;
                var txIn = inputs[index];
                ms.Write(txIn.PreviousOutput.Hash);
                ms.Write(WireSerialize.PackInt32Le((int)txIn.PreviousOutput.Index));
                if (sourceIndex == inputIndex)
                {
                    ms.Write(WireSerialize.WriteCompactSize(scriptCode.Length));
                    ms.Write(scriptCode);
                }
                else
                {
                    ms.WriteByte(0x00);
                }

                if (sourceIndex == inputIndex || baseType == 1)
                    ms.Write(WireSerialize.PackInt32Le((int)transaction.Inputs[sourceIndex].Sequence));
                else
                    ms.Write(new byte[4]);
            }

            if (baseType == 2)
                ms.Write(WireSerialize.WriteCompactSize(0));
            else if (baseType == 3)
                ms.Write(cache?.LegacySinglePlaceholderOutputs(transaction, inputIndex) ?? LegacySinglePlaceholderOutputs(transaction, inputIndex));
            else
                ms.Write(cache?.LegacyOutputsAll(transaction) ?? LegacyOutputsAll(transaction));

            ms.Write(WireSerialize.PackInt32Le((int)transaction.LockTime));
            ms.Write(WireSerialize.PackInt32Le(sighashType));
            return CryptoUtil.DoubleSha256(ms.ToArray());
        }
        finally
        {
            ScriptTiming.AddLegacySighash(System.Diagnostics.Stopwatch.GetTimestamp() - timingStarted);
        }
    }

    public static byte[] Bip143Sighash(
        Transaction transaction,
        int inputIndex,
        ReadOnlySpan<byte> scriptCode,
        long amount,
        byte sighashType = 1,
        SighashCache? cache = null)
    {
        var timingStarted = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            if (inputIndex >= transaction.Inputs.Count)
                throw new ArgumentOutOfRangeException(nameof(inputIndex));

            var anyoneCanPay = (sighashType & 0x80) != 0;
            var baseType = sighashType & 0x1f;

            var hashPrevouts = new byte[32];
            if (!anyoneCanPay)
            {
                hashPrevouts = cache?.Bip143Prevouts(transaction) ?? Bip143Prevouts(transaction);
            }

            var hashSequence = new byte[32];
            if (!anyoneCanPay && baseType is not (2 or 3))
                hashSequence = cache?.Bip143Sequences(transaction) ?? Bip143Sequences(transaction);

            var hashOutputs = new byte[32];
            if (baseType == 3)
            {
                if (inputIndex < transaction.Outputs.Count)
                    hashOutputs = CryptoUtil.DoubleSha256(cache?.SerializedOutput(transaction, inputIndex) ?? SerializeOutput(transaction.Outputs[inputIndex]));
            }
            else if (baseType != 2)
            {
                hashOutputs = cache?.Bip143OutputsAll(transaction) ?? Bip143OutputsAll(transaction);
            }

            var txIn = transaction.Inputs[inputIndex];
            using var payload = new MemoryStream();
            payload.Write(WireSerialize.PackInt32Le(transaction.Version));
            payload.Write(hashPrevouts);
            payload.Write(hashSequence);
            payload.Write(txIn.PreviousOutput.Hash);
            payload.Write(WireSerialize.PackInt32Le((int)txIn.PreviousOutput.Index));
            payload.Write(WireSerialize.WriteCompactSize(scriptCode.Length));
            payload.Write(scriptCode);
            payload.Write(WireSerialize.PackInt64Le(amount));
            payload.Write(WireSerialize.PackInt32Le((int)txIn.Sequence));
            payload.Write(hashOutputs);
            payload.Write(WireSerialize.PackInt32Le((int)transaction.LockTime));
            payload.Write(WireSerialize.PackInt32Le(sighashType));
            return CryptoUtil.DoubleSha256(payload.ToArray());
        }
        finally
        {
            ScriptTiming.AddBip143Sighash(System.Diagnostics.Stopwatch.GetTimestamp() - timingStarted);
        }
    }

    private static byte[] LegacyOutputsAll(Transaction transaction)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(transaction.Outputs.Count));
        foreach (var output in transaction.Outputs)
            ms.Write(SerializeOutput(output));
        return ms.ToArray();
    }

    private static byte[] LegacySinglePlaceholderOutputs(Transaction transaction, int inputIndex)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(inputIndex + 1));
        for (var i = 0; i < inputIndex; i++)
        {
            ms.Write(WireSerialize.PackInt64Le(-1));
            ms.Write(WireSerialize.WriteCompactSize(0));
        }
        ms.Write(SerializeOutput(transaction.Outputs[inputIndex]));
        return ms.ToArray();
    }

    private static byte[] Bip143Prevouts(Transaction transaction)
    {
        using var prevouts = new MemoryStream();
        foreach (var input in transaction.Inputs)
            prevouts.Write(SerializeOutPoint(input.PreviousOutput));
        return CryptoUtil.DoubleSha256(prevouts.ToArray());
    }

    private static byte[] Bip143Sequences(Transaction transaction)
    {
        using var sequences = new MemoryStream();
        foreach (var input in transaction.Inputs)
            sequences.Write(WireSerialize.PackInt32Le((int)input.Sequence));
        return CryptoUtil.DoubleSha256(sequences.ToArray());
    }

    private static byte[] Bip143OutputsAll(Transaction transaction)
    {
        using var outputs = new MemoryStream();
        foreach (var output in transaction.Outputs)
            outputs.Write(SerializeOutput(output));
        return CryptoUtil.DoubleSha256(outputs.ToArray());
    }

    internal static byte[] SerializeOutput(TxOut output)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.PackInt64Le(output.Value));
        ms.Write(WireSerialize.WriteCompactSize(output.ScriptPubKey.Length));
        ms.Write(output.ScriptPubKey);
        return ms.ToArray();
    }

    internal static byte[] SerializeOutPoint(OutPoint outPoint)
    {
        using var ms = new MemoryStream();
        ms.Write(outPoint.Hash);
        ms.Write(WireSerialize.PackInt32Le((int)outPoint.Index));
        return ms.ToArray();
    }
}
