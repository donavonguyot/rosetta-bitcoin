using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Tx;

namespace CsBitNode.Consensus.Script;

public sealed class ScriptError : Exception
{
    public ScriptError(string message) : base(message) { }
}

internal sealed class ScriptStack : List<byte[]>
{
    public byte[] PopItem()
    {
        if (Count == 0)
            throw new ScriptError("stack underflow");
        var item = this[^1];
        RemoveAt(Count - 1);
        return item;
    }

    public void PushItem(byte[] item) => Add(item);
}

public static class ScriptInterpreter
{
    public static byte[] P2pkhScriptCode(ReadOnlySpan<byte> pubkeyHash) =>
    [
        Opcodes.OP_DUP, Opcodes.OP_HASH160, (byte)pubkeyHash.Length,
        ..pubkeyHash,
        Opcodes.OP_EQUALVERIFY, Opcodes.OP_CHECKSIG
    ];

    public static bool VerifyScript(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness)
    {
        if (ScriptTemplates.IsP2pk(scriptPubKey))
            return VerifyP2pk(scriptSig, scriptPubKey, tx, inputIndex, amount);

        if (ScriptTemplates.IsP2wpkh(scriptPubKey))
            return VerifyP2wpkh(scriptPubKey, tx, inputIndex, amount, witness);

        return VerifyLegacy(scriptSig, scriptPubKey, tx, inputIndex, amount);
    }

    private static bool VerifyP2pk(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount)
    {
        if (!witnessEmpty(tx, inputIndex))
            return false;
        try
        {
            var pushes = ParsePushOnlyScriptSig(scriptSig);
            if (pushes.Count != 1 || pushes[0].Length == 0)
                return false;
        }
        catch (ScriptError)
        {
            return false;
        }

        var stackSig = new ScriptStack();
        try
        {
            EvaluateScript(scriptSig, stackSig, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false);
        }
        catch (ScriptError)
        {
            return false;
        }

        var stack = new ScriptStack();
        stack.AddRange(stackSig);
        try
        {
            EvaluateScript(scriptPubKey, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false);
        }
        catch (ScriptError)
        {
            return false;
        }

        return TerminalSuccessStrict(stack);
    }

    private static bool VerifyP2wpkh(
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness)
    {
        if (inputIndex < tx.Inputs.Count && tx.Inputs[inputIndex].ScriptSig.Length > 0)
            return false;
        var pubkeyHash = scriptPubKey[2..].ToArray();
        if (witness.Count != 2)
            return false;
        var scriptCode = P2pkhScriptCode(pubkeyHash);
        var stack = new ScriptStack();
        stack.AddRange(witness.Select(w => w.ToArray()));
        try
        {
            EvaluateScript(scriptCode, stack, tx, inputIndex, scriptCode, amount, witness: true);
        }
        catch (ScriptError)
        {
            return false;
        }
        return TerminalSuccessStrict(stack);
    }

    private static bool VerifyLegacy(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount)
    {
        var stackSig = new ScriptStack();
        try
        {
            EvaluateScript(scriptSig, stackSig, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false);
        }
        catch (ScriptError)
        {
            return false;
        }

        var stack = new ScriptStack();
        stack.AddRange(stackSig);
        try
        {
            EvaluateScript(scriptPubKey, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false);
        }
        catch (ScriptError)
        {
            return false;
        }

        return TerminalSuccessStrict(stack);
    }

    public static List<byte[]> ParsePushOnlyScriptSig(ReadOnlySpan<byte> scriptSig)
    {
        var offset = 0;
        var pushes = new List<byte[]>();
        while (offset < scriptSig.Length)
        {
            var opcode = scriptSig[offset];
            offset++;
            if (opcode == Opcodes.OP_0)
            {
                pushes.Add([]);
            }
            else if (opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
            {
                pushes.Add([(byte)(opcode - Opcodes.OP_1 + 1)]);
            }
            else if (opcode == Opcodes.OP_1NEGATE)
            {
                pushes.Add([0x81]);
            }
            else if (opcode is >= 1 and <= 75 or Opcodes.OP_PUSHDATA1 or Opcodes.OP_PUSHDATA2 or Opcodes.OP_PUSHDATA4)
            {
                offset--;
                var (item, next) = ReadPush(scriptSig, offset);
                offset = next;
                pushes.Add(item);
            }
            else
            {
                throw new ScriptError("non-push opcode in P2SH scriptSig");
            }
        }
        return pushes;
    }

    internal static void EvaluateScript(
        ReadOnlySpan<byte> script,
        ScriptStack stack,
        Transaction tx,
        int inputIndex,
        byte[] scriptCode,
        long amount,
        bool witness)
    {
        var offset = 0;
        while (offset < script.Length)
        {
            var opcode = script[offset];
            offset++;
            if (opcode == Opcodes.OP_0)
            {
                stack.PushItem([]);
            }
            else if (opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
            {
                stack.PushItem([(byte)(opcode - Opcodes.OP_1 + 1)]);
            }
            else if (opcode == Opcodes.OP_1NEGATE)
            {
                stack.PushItem([0x81]);
            }
            else if (opcode is >= 1 and <= 75 or Opcodes.OP_PUSHDATA1 or Opcodes.OP_PUSHDATA2 or Opcodes.OP_PUSHDATA4)
            {
                offset--;
                var (item, next) = ReadPush(script, offset);
                offset = next;
                stack.PushItem(item);
            }
            else if (opcode == Opcodes.OP_DUP)
            {
                var item = stack.PopItem();
                stack.PushItem(item);
                stack.PushItem(item);
            }
            else if (opcode == Opcodes.OP_HASH160)
            {
                stack.PushItem(Hash160.Compute(stack.PopItem()));
            }
            else if (opcode == Opcodes.OP_EQUAL)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                stack.PushItem(EncodeOpN(aVal.SequenceEqual(bVal) ? 1 : 0));
            }
            else if (opcode == Opcodes.OP_EQUALVERIFY)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                if (!aVal.SequenceEqual(bVal))
                    throw new ScriptError("EQUALVERIFY failed");
            }
            else if (opcode == Opcodes.OP_DROP)
            {
                stack.PopItem();
            }
            else if (opcode == Opcodes.OP_NOP)
            {
            }
            else if (opcode is Opcodes.OP_CHECKSIG or Opcodes.OP_CHECKSIGVERIFY)
            {
                var pubkey = stack.PopItem();
                var signature = stack.PopItem();
                var valid = CheckEcdsaSignature(signature, pubkey, tx, inputIndex, scriptCode, amount, witness);
                if (opcode == Opcodes.OP_CHECKSIG)
                    stack.PushItem(EncodeOpN(valid ? 1 : 0));
                else if (!valid)
                    throw new ScriptError("CHECKSIGVERIFY failed");
            }
            else if (opcode is Opcodes.OP_CHECKMULTISIG or Opcodes.OP_CHECKMULTISIGVERIFY)
            {
                var valid = CheckMultisig(stack, tx, inputIndex, scriptCode, amount, witness);
                if (opcode == Opcodes.OP_CHECKMULTISIG)
                    stack.PushItem(EncodeOpN(valid ? 1 : 0));
                else if (!valid)
                    throw new ScriptError("CHECKMULTISIGVERIFY failed");
            }
            else if (opcode == Opcodes.OP_CHECKLOCKTIMEVERIFY)
            {
                CheckLockTimeVerify(stack, tx, inputIndex);
            }
            else if (opcode == Opcodes.OP_CHECKSEQUENCEVERIFY)
            {
                CheckSequenceVerify(stack, tx, inputIndex);
            }
            else
            {
                throw new ScriptError($"unsupported opcode 0x{opcode:x2}");
            }
        }
    }

    private static bool CheckEcdsaSignature(
        ReadOnlySpan<byte> signature,
        ReadOnlySpan<byte> pubkey,
        Transaction tx,
        int inputIndex,
        byte[] scriptCode,
        long amount,
        bool witness)
    {
        if (signature.Length == 0)
            return false;
        var sighashType = signature[^1];
        var sigDer = signature[..^1];
        var digest = witness
            ? Sighash.Bip143Sighash(tx, inputIndex, scriptCode, amount, sighashType)
            : Sighash.LegacySighash(tx, inputIndex, scriptCode, sighashType);
        return Secp256k1.VerifyDerSignature(pubkey, digest, sigDer);
    }

    private static bool CheckMultisig(
        ScriptStack stack,
        Transaction tx,
        int inputIndex,
        byte[] scriptCode,
        long amount,
        bool witness)
    {
        var keyCount = DecodeScriptNum(ItemFromTop(stack, 1));
        if (keyCount < 0 || keyCount > 20)
            throw new ScriptError("pubkey count out of range");
        var keyStart = 2;
        var sigCountIndex = keyStart + keyCount;
        if (stack.Count < sigCountIndex)
            throw new ScriptError("CHECKMULTISIG stack underflow");
        var sigCount = DecodeScriptNum(ItemFromTop(stack, sigCountIndex));
        if (sigCount < 0 || sigCount > keyCount)
            throw new ScriptError("signature count out of range");
        var sigStart = sigCountIndex + 1;
        var dummyIndex = sigStart + sigCount;
        if (stack.Count < dummyIndex)
            throw new ScriptError("CHECKMULTISIG stack underflow");

        var success = true;
        var sigOffset = 0;
        var keyOffset = 0;
        var remainingSigs = sigCount;
        var remainingKeys = keyCount;
        while (success && remainingSigs > 0)
        {
            var signature = ItemFromTop(stack, sigStart + sigOffset);
            var pubkey = ItemFromTop(stack, keyStart + keyOffset);
            if (CheckEcdsaSignature(signature, pubkey, tx, inputIndex, scriptCode, amount, witness))
            {
                sigOffset++;
                remainingSigs--;
            }
            keyOffset++;
            remainingKeys--;
            if (remainingSigs > remainingKeys)
                success = false;
        }

        for (var i = 0; i < dummyIndex; i++)
            stack.PopItem();
        return success;
    }

    private static void CheckLockTimeVerify(ScriptStack stack, Transaction tx, int inputIndex)
    {
        if (stack.Count == 0)
            throw new ScriptError("CLTV stack underflow");
        var lockTime = DecodeScriptNumLong(stack[^1], maxLen: 5);
        if (lockTime < 0)
            throw new ScriptError("negative locktime");
        if (!SameLockTimeType(lockTime, tx.LockTime))
            throw new ScriptError("locktime type mismatch");
        if (lockTime > tx.LockTime)
            throw new ScriptError("locktime requirement not met");
        if (tx.Inputs[inputIndex].Sequence == 0xffff_ffff)
            throw new ScriptError("input sequence final for CLTV");
    }

    private static void CheckSequenceVerify(ScriptStack stack, Transaction tx, int inputIndex)
    {
        if (stack.Count == 0)
            throw new ScriptError("CSV stack underflow");
        var required = DecodeScriptNumLong(stack[^1], maxLen: 5);
        if (required < 0)
            throw new ScriptError("negative sequence");
        if ((required & (1L << 31)) != 0)
            return;
        if (tx.Version < 2)
            throw new ScriptError("transaction version below 2 for CSV");
        var sequence = tx.Inputs[inputIndex].Sequence;
        if ((sequence & (1u << 31)) != 0)
            throw new ScriptError("input sequence disabled for CSV");
        const long mask = 0x0040ffff;
        if (((long)sequence & mask) < (required & mask))
            throw new ScriptError("sequence requirement not met");
    }

    private static (byte[] Item, int Offset) ReadPush(ReadOnlySpan<byte> data, int offset)
    {
        var opcode = data[offset];
        offset++;
        if (opcode == Opcodes.OP_0)
            return ([], offset);
        if (opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
            return ([(byte)(opcode - Opcodes.OP_1 + 1)], offset);
        if (opcode == Opcodes.OP_1NEGATE)
            return ([0x81], offset);
        if (opcode is >= 1 and <= 75)
        {
            var end = offset + opcode;
            return (data[offset..end].ToArray(), end);
        }
        if (opcode == Opcodes.OP_PUSHDATA1)
        {
            var size = data[offset];
            offset++;
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        if (opcode == Opcodes.OP_PUSHDATA2)
        {
            var size = data[offset] | (data[offset + 1] << 8);
            offset += 2;
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        if (opcode == Opcodes.OP_PUSHDATA4)
        {
            var size = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24);
            offset += 4;
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        throw new ScriptError($"unsupported push opcode 0x{opcode:x2}");
    }

    private static bool CastToBool(ReadOnlySpan<byte> item)
    {
        foreach (var b in item)
        {
            if (b != 0)
                return b != 0x80;
        }
        return false;
    }

    private static byte[] ItemFromTop(ScriptStack stack, int oneBasedIndex)
    {
        if (oneBasedIndex <= 0 || stack.Count < oneBasedIndex)
            throw new ScriptError("stack underflow");
        return stack[stack.Count - oneBasedIndex];
    }

    private static int DecodeScriptNum(byte[] item, int maxLen = 4) => (int)DecodeScriptNumLong(item, maxLen);

    private static long DecodeScriptNumLong(byte[] item, int maxLen)
    {
        if (item.Length > maxLen)
            throw new ScriptError("script number overflow");
        if (item.Length == 0)
            return 0;
        var negative = (item[^1] & 0x80) != 0;
        long value = 0;
        for (var i = 0; i < item.Length; i++)
        {
            var b = item[i];
            if (i == item.Length - 1)
                b &= 0x7f;
            value |= (long)b << (8 * i);
        }
        return negative ? -value : value;
    }

    private static bool SameLockTimeType(long a, uint b) =>
        (a < 500_000_000 && b < 500_000_000) || (a >= 500_000_000 && b >= 500_000_000);

    private static byte[] EncodeOpN(int value) => value switch
    {
        0 => [],
        >= 1 and <= 16 => [(byte)value],
        _ => throw new ScriptError($"cannot encode numeric {value}")
    };

    internal static bool TerminalSuccessStrict(ScriptStack stack) =>
        stack.Count == 1 && CastToBool(stack[0]);

    internal static bool TerminalSuccessRelaxed(ScriptStack stack) =>
        stack.Count > 0 && CastToBool(stack[^1]);

    private static bool witnessEmpty(Transaction tx, int inputIndex) =>
        tx.Witness.Count == 0
        || inputIndex >= tx.Witness.Count
        || tx.Witness[inputIndex].Count == 0;
}
