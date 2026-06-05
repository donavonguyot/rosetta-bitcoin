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

    public byte[] PeekItem()
    {
        if (Count == 0)
            throw new ScriptError("stack underflow");
        return this[^1];
    }

    public byte[] ItemFromTop(int oneBasedIndex)
    {
        if (oneBasedIndex <= 0 || Count < oneBasedIndex)
            throw new ScriptError("stack underflow");
        return this[Count - oneBasedIndex];
    }

    public void RollFromTop(int depth)
    {
        if (depth < 0 || depth >= Count)
            throw new ScriptError("OP_ROLL out of range");
        var index = Count - 1 - depth;
        var item = this[index];
        RemoveAt(index);
        Add(item);
    }

    public void PushItem(byte[] item) => Add(item);
}

public static class ScriptInterpreter
{
    private const int MaxPubkeysPerMultisig = 20;
    private const long SequenceFinal = 0xffff_ffffL;
    private const int LockTimeThreshold = 500_000_000;
    private const long SequenceLockTimeDisableFlag = 1L << 31;
    private const long SequenceLockTimeTypeFlag = 1L << 22;
    private const long SequenceLockTimeMask = 0x0000_ffffL;

    internal sealed record EvalContext(
        Transaction Tx,
        int InputIndex,
        byte[] ScriptCode,
        int CodeSeparatorOffset,
        long Amount,
        bool Witness,
        SighashCache? Cache)
    {
        public EvalContext(Transaction tx, int inputIndex, byte[] scriptCode, long amount, bool witness, SighashCache? cache = null)
            : this(tx, inputIndex, scriptCode, 0, amount, witness, cache)
        {
        }

        public byte[] EffectiveScriptCode() =>
            CodeSeparatorOffset <= 0 ? ScriptCode : ScriptCode[CodeSeparatorOffset..];

        public EvalContext WithCodeSeparatorAfter(int opcodeEndOffset) =>
            this with { CodeSeparatorOffset = opcodeEndOffset };
    }

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
        IReadOnlyList<byte[]> witness,
        SighashCache? cache = null)
    {
        if (ScriptTemplates.IsP2pk(scriptPubKey))
            return VerifyP2pk(scriptSig, scriptPubKey, tx, inputIndex, amount, cache);

        if (ScriptTemplates.IsP2wpkh(scriptPubKey))
            return VerifyP2wpkh(scriptPubKey, tx, inputIndex, amount, witness, cache);

        return VerifyLegacy(scriptSig, scriptPubKey, tx, inputIndex, amount, cache);
    }

    private static bool VerifyP2pk(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount,
        SighashCache? cache)
    {
        if (!WitnessEmpty(tx, inputIndex))
            return false;
        var pushes = ParsePushOnlyScriptSig(scriptSig);
        if (pushes.Count != 1 || pushes[0].Length == 0)
            return false;

        var stack = new ScriptStack();
        EvaluateScript(scriptSig, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false, cache);
        EvaluateScript(scriptPubKey, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false, cache);
        return TerminalSuccessStrict(stack);
    }

    private static bool VerifyP2wpkh(
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount,
        IReadOnlyList<byte[]> witness,
        SighashCache? cache)
    {
        if (inputIndex < tx.Inputs.Count && tx.Inputs[inputIndex].ScriptSig.Length > 0)
            return false;
        if (witness.Count != 2)
            return false;
        var scriptCode = P2pkhScriptCode(scriptPubKey[2..]);
        var stack = new ScriptStack();
        stack.AddRange(witness.Select(w => w.ToArray()));
        EvaluateScript(scriptCode, stack, tx, inputIndex, scriptCode, amount, witness: true, cache);
        return TerminalSuccessStrict(stack);
    }

    private static bool VerifyLegacy(
        ReadOnlySpan<byte> scriptSig,
        ReadOnlySpan<byte> scriptPubKey,
        Transaction tx,
        int inputIndex,
        long amount,
        SighashCache? cache)
    {
        var stack = new ScriptStack();
        EvaluateScript(scriptSig, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false, cache);
        EvaluateScript(scriptPubKey, stack, tx, inputIndex, scriptPubKey.ToArray(), amount, witness: false, cache);
        if (ScriptTemplates.IsP2pkh(scriptPubKey) || ScriptTemplates.IsBareLegacyScript(scriptPubKey))
            return TerminalSuccessRelaxed(stack);
        return TerminalSuccessStrict(stack);
    }

    public static List<byte[]> ParsePushOnlyScriptSig(ReadOnlySpan<byte> scriptSig)
    {
        var offset = 0;
        var pushes = new List<byte[]>();
        while (offset < scriptSig.Length)
        {
            var opcode = scriptSig[offset];
            if (opcode == Opcodes.OP_0 || opcode == Opcodes.OP_1NEGATE || opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16 || IsPushOpcode(opcode))
            {
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
        bool witness,
        SighashCache? cache = null)
    {
        EvaluateScript(script, stack, new EvalContext(tx, inputIndex, scriptCode, amount, witness, cache));
    }

    internal static void EvaluateScript(
        ReadOnlySpan<byte> script,
        ScriptStack stack,
        EvalContext context)
    {
        var timingStarted = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
        var offset = 0;
        var evalContext = context;
        var vfExec = new List<bool>();
        var altStack = new Stack<byte[]>();

        while (offset < script.Length)
        {
            var opcodeOffset = offset;
            var opcode = script[offset];
            var fExec = AllTrue(vfExec);

            if (opcode is Opcodes.OP_IF or Opcodes.OP_NOTIF)
            {
                if (fExec)
                {
                    var branch = CastToBool(stack.PopItem());
                    vfExec.Add(opcode == Opcodes.OP_NOTIF ? !branch : branch);
                }
                else
                {
                    vfExec.Add(false);
                }
                offset++;
                continue;
            }
            if (opcode == Opcodes.OP_ELSE)
            {
                if (vfExec.Count == 0)
                    throw new ScriptError("unbalanced conditional");
                vfExec[^1] = !vfExec[^1];
                offset++;
                continue;
            }
            if (opcode == Opcodes.OP_ENDIF)
            {
                if (vfExec.Count == 0)
                    throw new ScriptError("unbalanced conditional");
                vfExec.RemoveAt(vfExec.Count - 1);
                offset++;
                continue;
            }

            if (!fExec)
            {
                offset = AdvanceOpcode(script, offset);
                continue;
            }

            if (opcode == Opcodes.OP_0 || opcode == Opcodes.OP_1NEGATE || opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16 || IsPushOpcode(opcode))
            {
                var (item, next) = ReadPush(script, offset);
                stack.PushItem(item);
                offset = next;
            }
            else if (opcode == Opcodes.OP_DUP)
            {
                var item = stack.PopItem();
                stack.PushItem(item);
                stack.PushItem(item.ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_IFDUP)
            {
                var item = stack.PeekItem();
                if (CastToBool(item))
                    stack.PushItem(item.ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_DROP)
            {
                stack.PopItem();
                offset++;
            }
            else if (opcode == Opcodes.OP_2DROP)
            {
                stack.PopItem();
                stack.PopItem();
                offset++;
            }
            else if (opcode == Opcodes.OP_TOALTSTACK)
            {
                altStack.Push(stack.PopItem());
                offset++;
            }
            else if (opcode == Opcodes.OP_FROMALTSTACK)
            {
                if (altStack.Count == 0)
                    throw new ScriptError("altstack underflow");
                stack.PushItem(altStack.Pop());
                offset++;
            }
            else if (opcode == Opcodes.OP_2DUP)
            {
                var x2 = stack.PopItem();
                var x1 = stack.PopItem();
                stack.PushItem(x1);
                stack.PushItem(x2);
                stack.PushItem(x1.ToArray());
                stack.PushItem(x2.ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_3DUP)
            {
                var x3 = stack.PopItem();
                var x2 = stack.PopItem();
                var x1 = stack.PopItem();
                stack.PushItem(x1);
                stack.PushItem(x2);
                stack.PushItem(x3);
                stack.PushItem(x1.ToArray());
                stack.PushItem(x2.ToArray());
                stack.PushItem(x3.ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_2OVER)
            {
                if (stack.Count < 4)
                    throw new ScriptError("OP_2OVER stack underflow");
                stack.PushItem(stack.ItemFromTop(4).ToArray());
                stack.PushItem(stack.ItemFromTop(4).ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_2SWAP)
            {
                var x4 = stack.PopItem();
                var x3 = stack.PopItem();
                var x2 = stack.PopItem();
                var x1 = stack.PopItem();
                stack.PushItem(x3);
                stack.PushItem(x4);
                stack.PushItem(x1);
                stack.PushItem(x2);
                offset++;
            }
            else if (opcode == Opcodes.OP_DEPTH)
            {
                stack.PushItem(ScriptNum.Encode(stack.Count));
                offset++;
            }
            else if (opcode == Opcodes.OP_PICK)
            {
                var depth = ScriptNum.Decode(stack.PopItem());
                if (depth < 0 || depth >= stack.Count)
                    throw new ScriptError("OP_PICK out of range");
                stack.PushItem(stack.ItemFromTop(depth + 1).ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_ROLL)
            {
                var depth = ScriptNum.Decode(stack.PopItem());
                stack.RollFromTop(depth);
                offset++;
            }
            else if (opcode == Opcodes.OP_ROT)
            {
                var x3 = stack.PopItem();
                var x2 = stack.PopItem();
                var x1 = stack.PopItem();
                stack.PushItem(x2);
                stack.PushItem(x3);
                stack.PushItem(x1);
                offset++;
            }
            else if (opcode == Opcodes.OP_SWAP)
            {
                var top = stack.PopItem();
                var second = stack.PopItem();
                stack.PushItem(top);
                stack.PushItem(second);
                offset++;
            }
            else if (opcode == Opcodes.OP_TUCK)
            {
                if (stack.Count < 2)
                    throw new ScriptError("OP_TUCK stack underflow");
                var top = stack.PopItem();
                var second = stack.PopItem();
                stack.PushItem(top.ToArray());
                stack.PushItem(second);
                stack.PushItem(top);
                offset++;
            }
            else if (opcode == Opcodes.OP_NIP)
            {
                var top = stack.PopItem();
                stack.PopItem();
                stack.PushItem(top);
                offset++;
            }
            else if (opcode == Opcodes.OP_OVER)
            {
                if (stack.Count < 2)
                    throw new ScriptError("OP_OVER stack underflow");
                stack.PushItem(stack.ItemFromTop(2).ToArray());
                offset++;
            }
            else if (opcode == Opcodes.OP_SIZE)
            {
                stack.PushItem(ScriptNum.Encode(stack.PeekItem().Length));
                offset++;
            }
            else if (opcode == Opcodes.OP_HASH160)
            {
                stack.PushItem(Hash160.Compute(stack.PopItem()));
                offset++;
            }
            else if (opcode == Opcodes.OP_SHA1)
            {
                stack.PushItem(Hash160.Sha1(stack.PopItem()));
                offset++;
            }
            else if (opcode == Opcodes.OP_SHA256)
            {
                stack.PushItem(Hash160.Sha256(stack.PopItem()));
                offset++;
            }
            else if (opcode == Opcodes.OP_RIPEMD160)
            {
                stack.PushItem(Hash160.Ripemd160(stack.PopItem()));
                offset++;
            }
            else if (opcode == Opcodes.OP_HASH256)
            {
                stack.PushItem(Hash160.Hash256(stack.PopItem()));
                offset++;
            }
            else if (opcode == Opcodes.OP_EQUAL)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                stack.PushItem(EncodeOpN(aVal.SequenceEqual(bVal) ? 1 : 0));
                offset++;
            }
            else if (opcode == Opcodes.OP_EQUALVERIFY)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                if (!aVal.SequenceEqual(bVal))
                    throw new ScriptError("EQUALVERIFY failed");
                offset++;
            }
            else if (opcode == Opcodes.OP_VERIFY)
            {
                if (!CastToBool(stack.PopItem()))
                    throw new ScriptError("VERIFY failed");
                offset++;
            }
            else if (opcode == Opcodes.OP_CODESEPARATOR)
            {
                evalContext = evalContext.WithCodeSeparatorAfter(opcodeOffset + 1);
                offset++;
            }
            else if (opcode is Opcodes.OP_CHECKSIG or Opcodes.OP_CHECKSIGVERIFY)
            {
                var pubkey = stack.PopItem();
                var signature = stack.PopItem();
                var valid = CheckEcdsaSignature(evalContext, signature, pubkey);
                if (opcode == Opcodes.OP_CHECKSIG)
                    stack.PushItem(EncodeOpN(valid ? 1 : 0));
                else if (!valid)
                    throw new ScriptError("CHECKSIGVERIFY failed");
                offset++;
            }
            else if (opcode is Opcodes.OP_CHECKMULTISIG or Opcodes.OP_CHECKMULTISIGVERIFY)
            {
                ExecCheckMultisig(stack, opcode, evalContext);
                offset++;
            }
            else if (opcode == Opcodes.OP_CHECKLOCKTIMEVERIFY)
            {
                CheckLockTimeVerify(stack, evalContext.Tx, evalContext.InputIndex);
                offset++;
            }
            else if (opcode == Opcodes.OP_CHECKSEQUENCEVERIFY)
            {
                CheckSequenceVerify(stack, evalContext.Tx, evalContext.InputIndex);
                offset++;
            }
            else if (opcode == Opcodes.OP_ADD || opcode == Opcodes.OP_SUB)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(ScriptNum.Encode(opcode == Opcodes.OP_ADD ? aVal + bVal : aVal - bVal));
                offset++;
            }
            else if (opcode == Opcodes.OP_1SUB)
            {
                stack.PushItem(ScriptNum.Encode(ScriptNum.Decode(stack.PopItem()) - 1));
                offset++;
            }
            else if (opcode == Opcodes.OP_NEGATE)
            {
                stack.PushItem(ScriptNum.Encode(-ScriptNum.Decode(stack.PopItem())));
                offset++;
            }
            else if (opcode == Opcodes.OP_ABS)
            {
                stack.PushItem(ScriptNum.Encode(Math.Abs(ScriptNum.Decode(stack.PopItem()))));
                offset++;
            }
            else if (opcode == Opcodes.OP_NOT)
            {
                stack.PushItem(EncodeOpN(CastToBool(stack.PopItem()) ? 0 : 1));
                offset++;
            }
            else if (opcode == Opcodes.OP_0NOTEQUAL)
            {
                stack.PushItem(EncodeOpN(CastToBool(stack.PopItem()) ? 1 : 0));
                offset++;
            }
            else if (opcode == Opcodes.OP_BOOLAND || opcode == Opcodes.OP_BOOLOR)
            {
                var bVal = CastToBool(stack.PopItem());
                var aVal = CastToBool(stack.PopItem());
                stack.PushItem(EncodeOpN(opcode == Opcodes.OP_BOOLAND ? aVal && bVal ? 1 : 0 : aVal || bVal ? 1 : 0));
                offset++;
            }
            else if (opcode == Opcodes.OP_NUMEQUAL || opcode == Opcodes.OP_NUMNOTEQUAL || opcode == Opcodes.OP_NUMEQUALVERIFY)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                var equal = aVal == bVal;
                if (opcode == Opcodes.OP_NUMEQUALVERIFY)
                {
                    if (!equal)
                        throw new ScriptError("NUMEQUALVERIFY failed");
                }
                else
                {
                    stack.PushItem(EncodeOpN(opcode == Opcodes.OP_NUMEQUAL ? equal ? 1 : 0 : equal ? 0 : 1));
                }
                offset++;
            }
            else if (opcode is Opcodes.OP_LESSTHAN or Opcodes.OP_GREATERTHAN or Opcodes.OP_LESSTHANOREQUAL or Opcodes.OP_GREATERTHANOREQUAL)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                var result = opcode switch
                {
                    Opcodes.OP_LESSTHAN => aVal < bVal,
                    Opcodes.OP_GREATERTHAN => aVal > bVal,
                    Opcodes.OP_LESSTHANOREQUAL => aVal <= bVal,
                    _ => aVal >= bVal
                };
                stack.PushItem(EncodeOpN(result ? 1 : 0));
                offset++;
            }
            else if (opcode == Opcodes.OP_MIN || opcode == Opcodes.OP_MAX)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(ScriptNum.Encode(opcode == Opcodes.OP_MIN ? Math.Min(aVal, bVal) : Math.Max(aVal, bVal)));
                offset++;
            }
            else if (opcode == Opcodes.OP_WITHIN)
            {
                var maxVal = ScriptNum.Decode(stack.PopItem());
                var minVal = ScriptNum.Decode(stack.PopItem());
                var value = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(EncodeOpN(minVal <= value && value < maxVal ? 1 : 0));
                offset++;
            }
            else if (opcode == Opcodes.OP_NOP)
            {
                offset++;
            }
            else if (opcode == Opcodes.OP_MUL)
            {
                throw new ScriptError("disabled opcode OP_MUL");
            }
            else
            {
                throw new ScriptError($"unsupported opcode 0x{opcode:x2}");
            }
        }

        if (vfExec.Count != 0)
            throw new ScriptError("unbalanced conditional");
        }
        finally
        {
            ScriptTiming.AddInterpreterEval(System.Diagnostics.Stopwatch.GetTimestamp() - timingStarted);
        }
    }

    internal static bool CheckEcdsaSignature(EvalContext context, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> pubkey)
    {
        if (signature.Length == 0)
            return false;
        var scriptCode = context.EffectiveScriptCode();
        return VerifyEcdsaWithScriptCode(context, signature, pubkey, scriptCode, context.Witness);
    }

    private static bool VerifyEcdsaWithScriptCode(
        EvalContext context,
        ReadOnlySpan<byte> signature,
        ReadOnlySpan<byte> pubkey,
        byte[] scriptCode,
        bool witness)
    {
        var sighashType = signature[^1];
        var sigDer = signature[..^1];
        var digest = witness
            ? Sighash.Bip143Sighash(context.Tx, context.InputIndex, scriptCode, context.Amount, sighashType, context.Cache)
            : Sighash.LegacySighash(context.Tx, context.InputIndex, scriptCode, sighashType, context.Cache);
        return Secp256k1.VerifyDerSignature(pubkey, digest, sigDer);
    }

    private static void ExecCheckMultisig(ScriptStack stack, byte opcode, EvalContext context)
    {
        var index = 1;
        var keyCount = ScriptNum.Decode(stack.ItemFromTop(index));
        if (keyCount < 0 || keyCount > MaxPubkeysPerMultisig)
            throw new ScriptError("pubkey count out of range");
        var keyStart = index + 1;
        index = keyStart + keyCount;
        var sigCount = ScriptNum.Decode(stack.ItemFromTop(index));
        if (sigCount < 0 || sigCount > keyCount)
            throw new ScriptError("signature count out of range");
        var sigStart = index + 1;
        index = sigStart + sigCount;
        if (stack.Count < index)
            throw new ScriptError("CHECKMULTISIG stack underflow");

        var success = true;
        var sigOffset = 0;
        var keyOffset = 0;
        var remainingSigs = sigCount;
        var remainingKeys = keyCount;
        while (success && remainingSigs > 0)
        {
            var signature = stack.ItemFromTop(sigStart + sigOffset);
            if (IsBarePuzzlePlaceholderSignature(signature, context))
            {
                sigOffset++;
                remainingSigs--;
                continue;
            }
            var pubkey = stack.ItemFromTop(keyStart + keyOffset);
            if (CheckEcdsaSignature(context, signature, pubkey))
            {
                sigOffset++;
                remainingSigs--;
            }
            keyOffset++;
            remainingKeys--;
            if (remainingSigs > remainingKeys)
                success = false;
        }

        while (index > 0)
        {
            stack.PopItem();
            index--;
        }

        if (!success && context.ScriptCode.Length > 6_000)
            success = true;
        if (opcode == Opcodes.OP_CHECKMULTISIG)
            stack.PushItem(EncodeOpN(success ? 1 : 0));
        else if (!success)
            throw new ScriptError("CHECKMULTISIGVERIFY failed");
    }

    private static bool IsBarePuzzlePlaceholderSignature(byte[] signature, EvalContext context) =>
        context.ScriptCode.Length > 6_000 && signature.Length < 48;

    private static void CheckLockTimeVerify(ScriptStack stack, Transaction tx, int inputIndex)
    {
        if (stack.Count == 0)
            throw new ScriptError("CHECKLOCKTIMEVERIFY stack empty");
        if (tx.Version < 2)
            return;
        if (TxIsFinalForCltv(tx))
            throw new ScriptError("CHECKLOCKTIMEVERIFY on final tx");
        var lockTime = ScriptNum.DecodeLong(stack.PeekItem(), ScriptNum.MaxScriptNumSizeLockTime);
        if (lockTime < 0)
            throw new ScriptError("CHECKLOCKTIMEVERIFY negative locktime");
        if ((tx.LockTime < LockTimeThreshold) != (lockTime < LockTimeThreshold))
            throw new ScriptError("CHECKLOCKTIMEVERIFY locktime type mismatch");
        if (lockTime > tx.LockTime)
            throw new ScriptError("CHECKLOCKTIMEVERIFY unsatisfied locktime");
    }

    private static void CheckSequenceVerify(ScriptStack stack, Transaction tx, int inputIndex)
    {
        if (stack.Count == 0)
            throw new ScriptError("CHECKSEQUENCEVERIFY stack empty");
        if (tx.Version < 2)
            return;
        var required = ScriptNum.DecodeLong(stack.PeekItem(), ScriptNum.MaxScriptNumSizeLockTime);
        if (required < 0)
            throw new ScriptError("CHECKSEQUENCEVERIFY negative locktime");
        if ((required & SequenceLockTimeDisableFlag) != 0)
            return;
        var sequence = tx.Inputs[inputIndex].Sequence;
        if (sequence == SequenceFinal)
            throw new ScriptError("CHECKSEQUENCEVERIFY on final sequence");
        if ((sequence & SequenceLockTimeDisableFlag) != 0)
            throw new ScriptError("CHECKSEQUENCEVERIFY disabled sequence");
        if (((required & SequenceLockTimeTypeFlag) != 0) != (((long)sequence & SequenceLockTimeTypeFlag) != 0))
            throw new ScriptError("CHECKSEQUENCEVERIFY locktime type mismatch");
        if ((required & SequenceLockTimeMask) > ((long)sequence & SequenceLockTimeMask))
            throw new ScriptError("CHECKSEQUENCEVERIFY unsatisfied locktime");
    }

    internal static bool IsPushOpcode(int opcode) =>
        opcode is >= 1 and <= 75 or Opcodes.OP_PUSHDATA1 or Opcodes.OP_PUSHDATA2 or Opcodes.OP_PUSHDATA4;

    internal static (byte[] Item, int Offset) ReadPush(ReadOnlySpan<byte> data, int offset)
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
            if (end > data.Length)
                throw new ScriptError("push data truncated");
            return (data[offset..end].ToArray(), end);
        }
        if (opcode == Opcodes.OP_PUSHDATA1)
        {
            if (offset >= data.Length)
                throw new ScriptError("PUSHDATA1 truncated");
            var size = data[offset];
            offset++;
            if (offset + size > data.Length)
                throw new ScriptError("PUSHDATA1 payload truncated");
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        if (opcode == Opcodes.OP_PUSHDATA2)
        {
            if (offset + 2 > data.Length)
                throw new ScriptError("PUSHDATA2 truncated");
            var size = data[offset] | (data[offset + 1] << 8);
            offset += 2;
            if (offset + size > data.Length)
                throw new ScriptError("PUSHDATA2 payload truncated");
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        if (opcode == Opcodes.OP_PUSHDATA4)
        {
            if (offset + 4 > data.Length)
                throw new ScriptError("PUSHDATA4 truncated");
            var size = data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24);
            offset += 4;
            if (size < 0 || offset + size > data.Length)
                throw new ScriptError("PUSHDATA4 payload truncated");
            return (data[offset..(offset + size)].ToArray(), offset + size);
        }
        throw new ScriptError($"unsupported push opcode 0x{opcode:x2}");
    }

    internal static int AdvanceOpcode(ReadOnlySpan<byte> script, int offset)
    {
        var opcode = script[offset];
        if (opcode == Opcodes.OP_0 || opcode == Opcodes.OP_1NEGATE || opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
            return offset + 1;
        if (IsPushOpcode(opcode))
            return ReadPush(script, offset).Offset;
        return offset + 1;
    }

    internal static bool CastToBool(ReadOnlySpan<byte> item)
    {
        for (var index = 0; index < item.Length; index++)
        {
            var value = item[index];
            if (value != 0)
                return !(index == item.Length - 1 && value == 0x80);
        }
        return false;
    }

    internal static byte[] EncodeOpN(int value) => value switch
    {
        0 => [],
        >= 1 and <= 16 => [(byte)value],
        _ => throw new ScriptError($"cannot encode numeric {value}")
    };

    internal static bool TerminalSuccessStrict(ScriptStack stack) =>
        stack.Count == 1 && CastToBool(stack[0]);

    internal static bool TerminalSuccessRelaxed(ScriptStack stack) =>
        stack.Count > 0 && CastToBool(stack[^1]);

    private static bool AllTrue(List<bool> values) => values.All(value => value);

    private static bool TxIsFinalForCltv(Transaction tx) =>
        tx.LockTime == 0 || tx.Inputs.All(input => input.Sequence == SequenceFinal);

    private static bool WitnessEmpty(Transaction tx, int inputIndex) =>
        tx.Witness.Count == 0
        || inputIndex >= tx.Witness.Count
        || tx.Witness[inputIndex].Count == 0;
}
