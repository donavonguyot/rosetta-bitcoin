using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Tx;
using CsBitNode.Wire;

namespace CsBitNode.Consensus.Script;

// BIP341 Taproot sighash; spent-prevout ordering and ext_flag bytes are consensus data.
public static class TaprootSighash
{
    public const int SighashDefault = 0;
    public const int SighashAll = 1;
    public const int SighashNone = 2;
    public const int SighashSingle = 3;

    public sealed record TaprootSighashOptions(
        int HashType,
        byte[]? Annex,
        int ExtFlag,
        byte[]? TapleafHash,
        long TapscriptCodeSeparatorPos)
    {
        public static TaprootSighashOptions KeyPath(int hashType) =>
            new(hashType, null, 0, null, 0xffff_ffffL);

        public static TaprootSighashOptions ScriptPath(
            int hashType,
            byte[]? annex,
            byte[] tapleafHash,
            long codeSeparatorPos) =>
            new(hashType, annex, 1, tapleafHash, codeSeparatorPos);
    }

    public static byte[] KeyPathSignatureHash(
        Transaction transaction,
        int inputIndex,
        IReadOnlyList<ScriptVerify.SpentPrevout> spentPrevouts,
        int hashType,
        SighashCache? cache = null)
    {
        return SignatureHash(transaction, inputIndex, spentPrevouts, TaprootSighashOptions.KeyPath(hashType), cache);
    }

    public static byte[] SignatureHash(
        Transaction transaction,
        int inputIndex,
        IReadOnlyList<ScriptVerify.SpentPrevout> spentPrevouts,
        TaprootSighashOptions options,
        SighashCache? cache = null)
    {
        return ScriptTiming.MeasureTaprootSighash(() =>
        {
            if (spentPrevouts.Count != transaction.Inputs.Count)
                throw new ArgumentException("spent_prevouts length mismatch");
            var hashType = options.HashType;
            if (!AllowedHashType(hashType))
                throw new ArgumentException("unsupported taproot sighash type");
            if (inputIndex >= transaction.Inputs.Count)
                throw new ArgumentOutOfRangeException(nameof(inputIndex));
            if (options.ExtFlag is not (0 or 1))
                throw new ArgumentException("invalid taproot ext_flag");
            if (options.ExtFlag == 1 && options.TapleafHash?.Length != 32)
                throw new ArgumentException("tapscript sighash requires 32-byte tapleaf_hash");

            var outputMode = hashType == SighashDefault ? SighashAll : hashType & 0x03;
            var anyoneCanPay = (hashType & 0x80) != 0;
            var annexPresent = options.Annex is not null;
            using var body = new MemoryStream();
            body.WriteByte((byte)hashType);
            body.Write(WireSerialize.PackInt32Le(transaction.Version));
            body.Write(WireSerialize.PackInt32Le((int)transaction.LockTime));

            if (!anyoneCanPay)
            {
                body.Write(cache?.TaprootPrevouts(transaction) ?? ShaPrevouts(transaction));
                body.Write(cache?.TaprootAmounts(spentPrevouts) ?? ShaAmounts(spentPrevouts));
                body.Write(cache?.TaprootScriptPubKeys(spentPrevouts) ?? ShaScriptPubKeys(spentPrevouts));
                body.Write(cache?.TaprootSequences(transaction) ?? ShaSequences(transaction));
            }

            if (outputMode == SighashAll)
                body.Write(cache?.TaprootOutputsAll(transaction) ?? ShaOutputsAll(transaction));
            else if (outputMode == SighashSingle && inputIndex >= transaction.Outputs.Count)
                throw new ArgumentException("SIGHASH_SINGLE without matching output");

            var spendType = (options.ExtFlag << 1) + (annexPresent ? 1 : 0);
            body.WriteByte((byte)spendType);
            if (anyoneCanPay)
            {
                var txIn = transaction.Inputs[inputIndex];
                var prevout = spentPrevouts[inputIndex];
                body.Write(Sighash.SerializeOutPoint(txIn.PreviousOutput));
                body.Write(Sighash.SerializeOutput(new TxOut(prevout.Amount, prevout.ScriptPubKey)));
                body.Write(WireSerialize.PackInt32Le((int)txIn.Sequence));
            }
            else
            {
                body.Write(WireSerialize.PackInt32Le(inputIndex));
            }

            if (annexPresent)
                body.Write(AnnexDigest(options.Annex!));

            if (outputMode == SighashSingle)
                body.Write(cache?.TaprootSingleOutputHash(transaction, inputIndex) ?? Hash160.Sha256(Sighash.SerializeOutput(transaction.Outputs[inputIndex])));

            if (options.ExtFlag == 1)
            {
                body.Write(options.TapleafHash!);
                body.WriteByte(0); // key version
                body.Write(WireSerialize.PackInt32Le((int)(options.TapscriptCodeSeparatorPos & 0xffff_ffffL)));
            }

            using var sigMsg = new MemoryStream();
            sigMsg.WriteByte(0);
            sigMsg.Write(body.ToArray());
            return TaprootHash.TaggedHash("TapSighash", sigMsg.ToArray());
        });
    }

    private static bool AllowedHashType(int hashType) =>
        hashType <= 0x03 || (hashType >= 0x81 && hashType <= 0x83);

    private static byte[] ShaPrevouts(Transaction transaction)
    {
        using var ms = new MemoryStream();
        foreach (var input in transaction.Inputs)
            ms.Write(Sighash.SerializeOutPoint(input.PreviousOutput));
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
            ms.Write(Sighash.SerializeOutput(output));
        return Hash160.Sha256(ms.ToArray());
    }

    private static byte[] AnnexDigest(byte[] annex)
    {
        using var ms = new MemoryStream();
        ms.Write(WireSerialize.WriteCompactSize(annex.Length));
        ms.Write(annex);
        return Hash160.Sha256(ms.ToArray());
    }

}
