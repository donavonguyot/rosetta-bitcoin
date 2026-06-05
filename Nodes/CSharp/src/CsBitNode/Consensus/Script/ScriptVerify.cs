using CsBitNode.Consensus.Hash;

namespace CsBitNode.Consensus.Script;

public static class ScriptTemplates
{
    private const int MaxConsensusScriptSize = 10_000;

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

    public static bool IsFutureWitnessProgram(ReadOnlySpan<byte> script) =>
        WitnessProgramVersion(script) is >= 1 && !IsP2tr(script);

    public static bool IsBareOpN(ReadOnlySpan<byte> script) =>
        script.Length > 0
        && (script[0] is >= Opcodes.OP_1 and <= Opcodes.OP_16 or Opcodes.OP_1NEGATE)
        && (script.Length == 1 || IsSinglePushTail(script[1..]));

    public static bool IsBareMultisig(ReadOnlySpan<byte> script)
    {
        if (script.Length < 4 || script[0] is < Opcodes.OP_1 or > Opcodes.OP_16)
            return false;
        var required = script[0] - Opcodes.OP_1 + 1;
        var offset = 1;
        var keyCount = 0;
        try
        {
            while (offset < script.Length)
            {
                var opcode = script[offset];
                if (opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
                    break;
                var (item, next) = ScriptInterpreter.ReadPush(script, offset);
                if (!IsEcdsaPubkey(item))
                    return false;
                keyCount++;
                if (keyCount > 20)
                    return false;
                offset = next;
            }
        }
        catch (ScriptError)
        {
            return false;
        }
        if (keyCount == 0 || keyCount < required || offset >= script.Length)
            return false;
        var nOpcode = script[offset++];
        if (nOpcode is < Opcodes.OP_1 or > Opcodes.OP_16 || nOpcode - Opcodes.OP_1 + 1 != keyCount)
            return false;
        return offset + 1 == script.Length && script[offset] == Opcodes.OP_CHECKMULTISIG;
    }

    public static bool IsBareLegacyScript(ReadOnlySpan<byte> script)
    {
        if (script.Length == 0 || script.Length > MaxConsensusScriptSize)
            return false;
        if (WitnessProgramVersion(script) is not null)
            return false;
        if (script.Length <= 83 && script[0] == 0x6a)
            return false;
        return !(IsP2pk(script)
            || IsP2pkh(script)
            || IsP2wpkh(script)
            || IsP2wsh(script)
            || IsP2sh(script)
            || IsP2tr(script)
            || IsBareOpN(script)
            || IsBareMultisig(script));
    }

    public static int? WitnessProgramVersion(ReadOnlySpan<byte> script)
    {
        if (script.Length < 4)
            return null;
        int? version = script[0] switch
        {
            0x00 => 0,
            >= Opcodes.OP_1 and <= Opcodes.OP_16 => script[0] - Opcodes.OP_1 + 1,
            _ => null
        };
        if (version is null)
            return null;
        try
        {
            var (program, next) = ScriptInterpreter.ReadPush(script, 1);
            if (next != script.Length || program.Length is < 2 or > 40)
                return null;
            return version;
        }
        catch (ScriptError)
        {
            return null;
        }
    }

    public static string Describe(ReadOnlySpan<byte> script)
    {
        if (IsP2pk(script)) return "P2PK";
        if (IsP2pkh(script)) return "P2PKH";
        if (IsP2wpkh(script)) return "P2WPKH";
        if (IsP2wsh(script)) return "P2WSH";
        if (IsP2sh(script)) return "P2SH";
        if (IsP2tr(script)) return "P2TR";
        if (IsFutureWitnessProgram(script)) return "future_witness";
        if (IsBareOpN(script)) return "bare_op_n";
        if (IsBareMultisig(script)) return "bare_multisig";
        if (IsBareLegacyScript(script)) return "bare_legacy";
        return "unknown";
    }

    private static bool IsSinglePushTail(ReadOnlySpan<byte> tail)
    {
        if (tail.Length == 0)
            return false;
        try
        {
            return ScriptInterpreter.ReadPush(tail, 0).Offset == tail.Length;
        }
        catch (ScriptError)
        {
            return false;
        }
    }

    private static bool IsEcdsaPubkey(ReadOnlySpan<byte> item) =>
        item.Length == 33 && item[0] is 0x02 or 0x03
        || item.Length == 65 && item[0] == 0x04;
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
        VerifyTransactionInput(transaction, inputIndex, options, null);
    }

    internal static void VerifyTransactionInput(
        Tx.Transaction transaction,
        int inputIndex,
        VerifyInputOptions options,
        SighashCache? cache)
    {
        if (inputIndex >= transaction.Inputs.Count)
            throw new ScriptVerifyError("input index out of range");

        var scriptPubKey = options.ScriptPubKey;
        if (!(ScriptTemplates.IsP2pk(scriptPubKey)
              || ScriptTemplates.IsP2pkh(scriptPubKey)
              || ScriptTemplates.IsP2wpkh(scriptPubKey)
              || ScriptTemplates.IsP2wsh(scriptPubKey)
              || ScriptTemplates.IsP2sh(scriptPubKey)
              || ScriptTemplates.IsP2tr(scriptPubKey)
              || ScriptTemplates.IsFutureWitnessProgram(scriptPubKey)
              || ScriptTemplates.IsBareOpN(scriptPubKey)
              || ScriptTemplates.IsBareMultisig(scriptPubKey)
              || ScriptTemplates.IsBareLegacyScript(scriptPubKey)))
        {
            throw new ScriptVerifyError("unsupported scriptPubKey template");
        }

        IReadOnlyList<byte[]> witness = inputIndex < transaction.Witness.Count
            ? transaction.Witness[inputIndex]
            : Array.Empty<byte[]>();

        bool ok;
        try
        {
            ok = VerifyScript(
                transaction.Inputs[inputIndex].ScriptSig,
                scriptPubKey,
                transaction,
                inputIndex,
                options.Amount,
                witness,
                options.SpentPrevouts,
                cache);
        }
        catch (ScriptError error)
        {
            throw new ScriptVerifyError(error.Message);
        }
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
        IReadOnlyList<SpentPrevout>? spentPrevouts,
        SighashCache? cache)
    {
        if (ScriptTemplates.IsP2tr(scriptPubKey))
            return VerifyTaproot(scriptSig, scriptPubKey, transaction, inputIndex, witness, spentPrevouts, cache);
        if (ScriptTemplates.IsFutureWitnessProgram(scriptPubKey))
            return scriptSig.Length == 0;
        if (ScriptTemplates.IsP2wpkh(scriptPubKey))
            return ScriptInterpreter.VerifyScript(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, cache);
        if (ScriptTemplates.IsP2wsh(scriptPubKey))
            return VerifyP2wsh(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, cache);
        if (ScriptTemplates.IsP2sh(scriptPubKey))
            return VerifyP2sh(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, cache);
        if (witness.Count > 0)
            return false;
        return ScriptInterpreter.VerifyScript(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, cache);
    }

    private static bool VerifyP2sh(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness,
        SighashCache? cache)
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
            return VerifyP2wpkhWitness(redeemScript, transaction, inputIndex, amount, witness, cache);
        if (ScriptTemplates.IsP2wsh(redeemScript))
            return VerifyP2wshWitness(redeemScript[2..].ToArray(), transaction, inputIndex, amount, witness, 1, cache);

        var stack = new ScriptStack();
        for (var i = 0; i < pushes.Count - 1; i++)
            stack.PushItem(pushes[i]);
        try
        {
            ScriptInterpreter.EvaluateScript(redeemScript, stack, transaction, inputIndex, redeemScript, amount, witness: false, cache);
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
        IReadOnlyList<byte[]> witness,
        SighashCache? cache)
    {
        if (witness.Count != 2)
            return false;
        var scriptCode = ScriptInterpreter.P2pkhScriptCode(scriptPubKey[2..]);
        var stack = new ScriptStack();
        stack.AddRange(witness.Select(w => w.ToArray()));
        try
        {
            ScriptInterpreter.EvaluateScript(scriptCode, stack, transaction, inputIndex, scriptCode, amount, witness: true, cache);
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
        IReadOnlyList<byte[]> witness,
        SighashCache? cache)
    {
        if (scriptSig.Length > 0)
            return false;
        return VerifyP2wshWitness(scriptPubKey[2..].ToArray(), transaction, inputIndex, amount, witness, 1, cache);
    }

    private static bool VerifyP2wshWitness(
        byte[] witnessProgram,
        Tx.Transaction transaction,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness,
        int minWitnessItems,
        SighashCache? cache)
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
            ScriptInterpreter.EvaluateScript(witnessScript, stack, transaction, inputIndex, witnessScript, amount, witness: true, cache);
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
        IReadOnlyList<SpentPrevout>? spentPrevouts,
        SighashCache? cache)
    {
        if (scriptSig.Length > 0 || spentPrevouts is null)
            return false;
        if (witness.Count == 0)
            return false;
        if (witness.Count >= 2)
            return VerifyTaprootScriptPath(scriptPubKey, transaction, inputIndex, witness, spentPrevouts, cache);

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
            var message = TaprootSighash.KeyPathSignatureHash(transaction, inputIndex, spentPrevouts, hashType, cache);
            return Secp256k1.VerifySchnorrSignature(scriptPubKey[2..], message, sig64);
        }
        catch
        {
            return false;
        }
    }

    private static bool VerifyTaprootScriptPath(
        ReadOnlySpan<byte> scriptPubKey,
        Tx.Transaction transaction,
        int inputIndex,
        IReadOnlyList<byte[]> witness,
        IReadOnlyList<SpentPrevout> spentPrevouts,
        SighashCache? cache)
    {
        if (spentPrevouts.Count != transaction.Inputs.Count || witness.Count < 2)
            return false;

        var serializedWitnessForWeight = TaprootHash.SerializedWitnessStackBytes(witness);
        var items = witness.Select(item => item.ToArray()).ToList();
        byte[]? annex = null;
        if (items.Count >= 3 && items[^2].Length > 0 && items[^2][0] == 0x50)
        {
            annex = items[^2];
            items.RemoveAt(items.Count - 2);
        }

        if (items.Count < 2)
            return false;
        var scriptBytes = items[^2];
        var control = items[^1];
        var stackItems = items.Take(items.Count - 2).ToList();
        if (scriptBytes.Length == 0)
            return false;
        if (control.Length < 33 || control.Length > 33 + 128 * 32 || (control.Length - 33) % 32 != 0)
            return false;

        var leafMasked = control[0] & 0xfe;
        if (leafMasked == 0x50)
            return false;
        var internalX = control[1..33];
        var branch = new List<byte[]>();
        for (var offset = 33; offset < control.Length; offset += 32)
            branch.Add(control[offset..(offset + 32)]);

        byte[] leafHash;
        Secp256k1.TaprootTweakResult tweak;
        try
        {
            leafHash = TaprootHash.TapLeafHash(leafMasked, scriptBytes);
            var merkleRoot = TaprootHash.MerkleRootFromBranch(branch, leafHash);
            tweak = Secp256k1.TaprootTweakPubkeyXOnly(internalX, merkleRoot);
        }
        catch
        {
            return false;
        }

        if (!scriptPubKey[2..].SequenceEqual(tweak.OutputXOnly) || control[0] != (byte)(leafMasked | tweak.Parity))
            return false;

        if (leafMasked != TaprootHash.TaprootLeafVersionTapscript)
            return true;
        if (Tapscript.PrescanOpSuccess(scriptBytes))
            return true;
        if (stackItems.Count > Tapscript.MaxTapscriptStackElements)
            return false;
        foreach (var item in stackItems)
            if (item.Length > Tapscript.MaxScriptElementSizeConsensus)
                return false;

        var stack = new ScriptStack();
        foreach (var item in stackItems)
            stack.PushItem(item);
        var budget = Tapscript.ValidationWeightOffset + serializedWitnessForWeight.Length;
        Tapscript.Evaluate(scriptBytes, stack, transaction, inputIndex, leafHash, spentPrevouts, annex, ref budget, cache);
        return ScriptInterpreter.TerminalSuccessStrict(stack);
    }
}
