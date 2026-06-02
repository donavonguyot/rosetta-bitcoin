using CsBitNode.Consensus.Hash;

namespace CsBitNode.Consensus.Script;

public static class ScriptTemplates
{
    public static bool IsP2pk(ReadOnlySpan<byte> script) =>
        (script.Length == 35 && script[0] == 0x21 && script[^1] == Opcodes.OP_CHECKSIG)
        || (script.Length == 67 && script[0] == 0x41 && script[^1] == Opcodes.OP_CHECKSIG);

    public static bool IsP2pkh(ReadOnlySpan<byte> script) =>
        script.Length == 25 && script[0] == 0x76 && script[1] == 0xa9 && script[2] == 0x14 && script[23] == 0x88 && script[24] == 0xac;

    public static bool IsP2wpkh(ReadOnlySpan<byte> script) =>
        script.Length == 22 && script[0] == 0x00 && script[1] == 0x14;

    public static bool IsP2wsh(ReadOnlySpan<byte> script) =>
        script.Length == 34 && script[0] == 0x00 && script[1] == 0x20;

    public static bool IsP2sh(ReadOnlySpan<byte> script) =>
        script.Length == 23 && script[0] == 0xa9 && script[1] == 0x14 && script[22] == 0x87;

    public static bool IsP2tr(ReadOnlySpan<byte> script) =>
        script.Length == 34 && script[0] == 0x51 && script[1] == 0x20;

    public static bool IsBareOpN(ReadOnlySpan<byte> script) =>
        script.Length == 1 && script[0] >= 0x51 && script[0] <= 0x60;

    public static int? WitnessProgramVersion(ReadOnlySpan<byte> script)
    {
        if (script.Length < 2)
            return null;
        return script[0] switch
        {
            0x00 => 0,
            0x51 => 1,
            _ => null
        };
    }

    public static string Describe(ReadOnlySpan<byte> script)
    {
        if (IsP2pk(script)) return "P2PK";
        if (IsP2pkh(script)) return "P2PKH";
        if (IsP2wpkh(script)) return "P2WPKH";
        if (IsP2wsh(script)) return "P2WSH";
        if (IsP2sh(script)) return "P2SH";
        if (IsP2tr(script)) return "P2TR";
        if (IsBareOpN(script)) return "bare_op_n";
        return "unknown";
    }
}

public sealed class ScriptVerifyError : Exception
{
    public ScriptVerifyError(string message) : base(message) { }
}

public sealed class UnsupportedScriptRule : Exception
{
    public UnsupportedScriptRule(string rule, string message) : base(message) => Rule = rule;
    public string Rule { get; }
}

public static class ScriptVerify
{
    private const int MaxP2shRedeemPush = 520;
    private const int MaxConsensusScriptSize = 10_000;

    public sealed record SpentPrevout(long Amount, byte[] ScriptPubKey);
    public sealed record VerifyInputOptions(byte[] ScriptPubKey, long Amount, IReadOnlyList<SpentPrevout>? SpentPrevouts);

    public static void VerifyTransactionInput(
        Tx.Transaction transaction,
        int inputIndex,
        VerifyInputOptions options)
    {
        if (inputIndex >= transaction.Inputs.Count)
            throw new ScriptVerifyError("input index out of range");

        var scriptPubKey = options.ScriptPubKey;
        var witnessVersion = ScriptTemplates.WitnessProgramVersion(scriptPubKey);
        if (witnessVersion is > 1)
            throw new ScriptVerifyError($"unsupported witness program version {witnessVersion}");

        if (!(ScriptTemplates.IsP2pk(scriptPubKey)
              || ScriptTemplates.IsP2pkh(scriptPubKey)
              || ScriptTemplates.IsP2wpkh(scriptPubKey)
              || ScriptTemplates.IsP2wsh(scriptPubKey)
              || ScriptTemplates.IsP2sh(scriptPubKey)
              || ScriptTemplates.IsP2tr(scriptPubKey)
              || ScriptTemplates.IsBareOpN(scriptPubKey)))
        {
            throw new ScriptVerifyError("unsupported scriptPubKey template");
        }

        IReadOnlyList<byte[]> witness = inputIndex < transaction.Witness.Count
            ? transaction.Witness[inputIndex]
            : Array.Empty<byte[]>();

        var ok = VerifyScript(
            transaction.Inputs[inputIndex].ScriptSig,
            scriptPubKey,
            transaction,
            inputIndex,
            options.Amount,
            witness,
            options.SpentPrevouts);
        if (!ok)
        {
            throw new ScriptVerifyError($"script verification failed for input {inputIndex}");
        }
    }

    private static bool VerifyScript(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness,
        IReadOnlyList<SpentPrevout>? spentPrevouts)
    {
        if (ScriptTemplates.IsP2tr(scriptPubKey))
            return VerifyTaproot(scriptSig, scriptPubKey, transaction, inputIndex, witness, spentPrevouts);
        if (ScriptTemplates.IsP2wsh(scriptPubKey))
            return VerifyP2wsh(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness);
        if (ScriptTemplates.IsP2sh(scriptPubKey))
            return VerifyP2sh(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness);
        return ScriptInterpreter.VerifyScript(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness);
    }

    private static bool VerifyP2sh(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness)
    {
        List<byte[]> pushes;
        try
        {
            pushes = ScriptInterpreter.ParsePushOnlyScriptSig(scriptSig);
        }
        catch (ScriptError)
        {
            return false;
        }
        if (pushes.Count == 0 || pushes[^1].Length > MaxP2shRedeemPush)
            return false;
        var redeemScript = pushes[^1];
        if (!Hash160.Compute(redeemScript).SequenceEqual(scriptPubKey[2..22].ToArray()))
            return false;
        if (ScriptTemplates.IsP2wpkh(redeemScript))
            return VerifyP2wpkhWitness(redeemScript, transaction, inputIndex, amount, witness);
        if (ScriptTemplates.IsP2wsh(redeemScript))
            return VerifyP2wshWitness(redeemScript[2..].ToArray(), transaction, inputIndex, amount, witness, 1);

        var stack = new ScriptStack();
        for (var i = 0; i < pushes.Count - 1; i++)
            stack.PushItem(pushes[i]);
        try
        {
            ScriptInterpreter.EvaluateScript(redeemScript, stack, transaction, inputIndex, redeemScript, amount, witness: false);
        }
        catch (ScriptError)
        {
            return false;
        }
        return ScriptInterpreter.TerminalSuccessRelaxed(stack);
    }

    private static bool VerifyP2wpkhWitness(
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness)
    {
        if (witness.Count != 2)
            return false;
        var scriptCode = ScriptInterpreter.P2pkhScriptCode(scriptPubKey[2..]);
        var stack = new ScriptStack();
        stack.AddRange(witness.Select(w => w.ToArray()));
        try
        {
            ScriptInterpreter.EvaluateScript(scriptCode, stack, transaction, inputIndex, scriptCode, amount, witness: true);
        }
        catch (ScriptError)
        {
            return false;
        }
        return ScriptInterpreter.TerminalSuccessStrict(stack);
    }

    private static bool VerifyP2wsh(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness)
    {
        if (scriptSig.Length > 0)
            return false;
        return VerifyP2wshWitness(scriptPubKey[2..].ToArray(), transaction, inputIndex, amount, witness, 1);
    }

    private static bool VerifyP2wshWitness(
        byte[] witnessProgram,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness,
        int minWitnessItems)
    {
        if (witness.Count < minWitnessItems)
            return false;
        var witnessScript = witness[^1];
        if (witnessScript.Length == 0 || witnessScript.Length > MaxConsensusScriptSize)
            return false;
        if (!Hash160.Sha256(witnessScript).SequenceEqual(witnessProgram))
            return false;
        var stack = new ScriptStack();
        for (var i = 0; i < witness.Count - 1; i++)
            stack.PushItem(witness[i].ToArray());
        try
        {
            ScriptInterpreter.EvaluateScript(witnessScript, stack, transaction, inputIndex, witnessScript, amount, witness: true);
        }
        catch (ScriptError)
        {
            return false;
        }
        return ScriptInterpreter.TerminalSuccessStrict(stack);
    }

    private static bool VerifyTaproot(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        IReadOnlyList<byte[]> witness,
        IReadOnlyList<SpentPrevout>? spentPrevouts)
    {
        if (scriptSig.Length > 0 || spentPrevouts is null || witness.Count != 1)
            return false;
        var sigBlob = witness[0];
        if (sigBlob.Length is not (64 or 65))
            return false;
        var hashType = TaprootSighash.SighashDefault;
        var sig64 = sigBlob;
        if (sigBlob.Length == 65)
        {
            hashType = sigBlob[64];
            if (hashType == TaprootSighash.SighashDefault)
                return false;
            sig64 = sigBlob[..64];
        }
        try
        {
            var message = TaprootSighash.KeyPathSignatureHash(transaction, inputIndex, spentPrevouts, hashType);
            return Secp256k1.VerifySchnorrSignature(scriptPubKey[2..], message, sig64);
        }
        catch
        {
            return false;
        }
    }
}
