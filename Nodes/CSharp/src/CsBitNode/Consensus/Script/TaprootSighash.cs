using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Tx;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Script;

public static class TaprootSighash
{
    public const int SighashDefault = 0;
    public const int SighashAll = 1;
    public const int SighashNone = 2;
    public const int SighashSingle = 3;

    public static byte[] KeyPathSignatureHash(
        Transaction transaction,
        int inputIndex,
        IReadOnlyList<ScriptVerify.SpentPrevout> spentPrevouts,
        int hashType)
    {
        if (spentPrevouts.Count != transaction.Inputs.Count)
            throw new ArgumentException("spent_prevouts length mismatch");
        if (!AllowedHashType(hashType))
            throw new ArgumentException("unsupported taproot sighash type");
        if (inputIndex >= transaction.Inputs.Count)
            throw new ArgumentOutOfRangeException(nameof(inputIndex));

        var outputMode = hashType == SighashDefault ? SighashAll : hashType & 0x03;
        var anyoneCanPay = (hashType & 0x80) != 0;
        using var body = new MemoryStream();
        body.WriteByte((byte)hashType);
        body.Write(WireSerialize.PackInt32Le(transaction.Version));
        body.Write(WireSerialize.PackInt32Le((int)transaction.LockTime));

        if (!anyoneCanPay)
        {
            body.Write(ShaPrevouts(transaction));
            body.Write(ShaAmounts(spentPrevouts));
            body.Write(ShaScriptPubKeys(spentPrevouts));
            body.Write(ShaSequences(transaction));
        }

        if (outputMode == SighashAll)
            body.Write(ShaOutputsAll(transaction));
        else if (outputMode == SighashSingle && inputIndex >= transaction.Outputs.Count)
            throw new ArgumentException("SIGHASH_SINGLE without matching output");

        body.WriteByte(0); // spend_type: key path, no annex.
        if (anyoneCanPay)
        {
            var txIn = transaction.Inputs[inputIndex];
            var prevout = spentPrevouts[inputIndex];
            body.Write(SerializeOutPoint(txIn.PreviousOutput));
            body.Write(SerializeOutput(new TxOut(prevout.Amount, prevout.ScriptPubKey)));
            body.Write(WireSerialize.PackInt32Le((int)txIn.Sequence));
        }
        else
        {
            body.Write(WireSerialize.PackInt32Le(inputIndex));
        }

        if (outputMode == SighashSingle)
            body.Write(Hash160.Sha256(SerializeOutput(transaction.Outputs[inputIndex])));

        using var sigMsg = new MemoryStream();
        sigMsg.WriteByte(0);
        sigMsg.Write(body.ToArray());
        return TaggedHash("TapSighash", sigMsg.ToArray());
    }

    private static bool AllowedHashType(int hashType) =>
        hashType <= 0x03 || (hashType >= 0x81 && hashType <= 0x83);

    private static byte[] ShaPrevouts(Transaction transaction)
    {
        using var ms = new MemoryStream();
        foreach (var input in transaction.Inputs)
            ms.Write(SerializeOutPoint(input.PreviousOutput));
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] ShaAmounts(IReadOnlyList<ScriptVerify.SpentPrevout> prevouts)
    {
        using var ms = new MemoryStream();
        foreach (var prevout in prevouts)
            ms.Write(WireSerialize.PackInt64Le(prevout.Amount));
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] ShaScriptPubKeys(IReadOnlyList<ScriptVerify.SpentPrevout> prevouts)
    {
        using var ms = new MemoryStream();
        foreach (var prevout in prevouts)
        {
            ms.Write(WireSerialize.WriteCompactSize(prevout.ScriptPubKey.Length));
            ms.Write(prevout.ScriptPubKey);
        }
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] ShaSequences(Transaction transaction)
    {
        using var ms = new MemoryStream();
        foreach (var input in transaction.Inputs)
            ms.Write(WireSerialize.PackInt32Le((int)input.Sequence));
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] ShaOutputsAll(Transaction transaction)
    {
        using var ms = new MemoryStream();
        foreach (var output in transaction.Outputs)
            ms.Write(SerializeOutput(output));
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] SerializeOutPoint(OutPoint outPoint)
    {
        using var ms = new MemoryStream();
        ms.Write(outPoint.Hash);
        ms.Write(WireSerialize.PackInt32Le((int)outPoint.Index));
        return ms.ToArray();
    }

    private static byte[] SerializeOutput(TxOut output)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.PackInt64Le(output.Value));
        ms.Write(WireSerialize.WriteCompactSize(output.ScriptPubKey.Length));
        ms.Write(output.ScriptPubKey);
        return ms.ToArray();
    }

    private static byte[] TaggedHash(string tag, ReadOnlySpan<byte> payload)
    {
        var tagHash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.ASCII.GetBytes(tag));
        var buffer = new byte[tagHash.Length * 2 + payload.Length];
        tagHash.CopyTo(buffer, 0);
        tagHash.CopyTo(buffer, tagHash.Length);
        payload.CopyTo(buffer.AsSpan(tagHash.Length * 2));
        return System.Security.Cryptography.SHA256.HashData(buffer);
    }
}
