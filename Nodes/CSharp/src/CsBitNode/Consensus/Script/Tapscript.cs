using CsBitNode.Consensus.Hash;
using CsBitNode.Consensus.Tx;

namespace CsBitNode.Consensus.Script;

internal static class Tapscript
{
    public const int MaxTapscriptStackElements = 1000;
    public const int MaxScriptElementSizeConsensus = 520;
    public const int ValidationWeightOffset = 50;
    private const int ValidationWeightPerSigop = 50;
    private const long SequenceFinal = 0xffff_ffffL;
    private const int LockTimeThreshold = 500_000_000;
    private const long SequenceLockTimeDisableFlag = 1L << 31;
    private const long SequenceLockTimeTypeFlag = 1L << 22;
    private const long SequenceLockTimeMask = 0x0000_ffffL;

    public static bool PrescanOpSuccess(ReadOnlySpan<byte> script)
    {
        var offset = 0;
        while (offset < script.Length)
        {
            var opcode = script[offset];
            if (opcode == Opcodes.OP_0 || opcode == Opcodes.OP_1NEGATE || opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16)
            {
                offset++;
                continue;
            }
            if (ScriptInterpreter.IsPushOpcode(opcode))
            {
                try
                {
                    offset = ScriptInterpreter.ReadPush(script, offset).Offset;
                }
                catch (ScriptError)
                {
                    return false;
                }
                continue;
            }
            if (OpcodeIsSuccess(opcode))
                return true;
            offset++;
        }
        return false;
    }

    public static void Evaluate(
        ReadOnlySpan<byte> script,
        ScriptStack stack,
        Transaction tx,
        int inputIndex,
        byte[] tapleafHash,
        IReadOnlyList<ScriptVerify.SpentPrevout> spentPrevouts,
        byte[]? annex,
        ref int validationBudgetLeft,
        SighashCache? cache = null)
    {
        if (PrescanOpSuccess(script))
            return;

        long codeSeparatorPos = 0xffff_ffffL;
        var instructionPos = 0;
        var offset = 0;
        var vfExec = new List<bool>();
        var altStack = new Stack<byte[]>();

        while (offset < script.Length)
        {
            var instrAt = instructionPos;
            var opcode = script[offset];
            var fExec = vfExec.All(value => value);

            if (opcode is Opcodes.OP_IF or Opcodes.OP_NOTIF)
            {
                if (fExec)
                {
                    var branch = ScriptInterpreter.CastToBool(stack.PopItem());
                    vfExec.Add(opcode == Opcodes.OP_NOTIF ? !branch : branch);
                }
                else
                {
                    vfExec.Add(false);
                }
                offset++;
                instructionPos++;
                continue;
            }
            if (opcode == Opcodes.OP_ELSE)
            {
                if (vfExec.Count == 0)
                    throw new ScriptError("unbalanced conditional");
                vfExec[^1] = !vfExec[^1];
                offset++;
                instructionPos++;
                continue;
            }
            if (opcode == Opcodes.OP_ENDIF)
            {
                if (vfExec.Count == 0)
                    throw new ScriptError("unbalanced conditional");
                vfExec.RemoveAt(vfExec.Count - 1);
                offset++;
                instructionPos++;
                continue;
            }

            if (!fExec)
            {
                offset = ScriptInterpreter.AdvanceOpcode(script, offset);
                instructionPos++;
                continue;
            }

            if (opcode == Opcodes.OP_0 || opcode == Opcodes.OP_1NEGATE || opcode is >= Opcodes.OP_1 and <= Opcodes.OP_16 || ScriptInterpreter.IsPushOpcode(opcode))
            {
                var (item, next) = ScriptInterpreter.ReadPush(script, offset);
                stack.PushItem(item);
                offset = next;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_DROP)
            {
                stack.PopItem();
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_2DROP)
            {
                stack.PopItem();
                stack.PopItem();
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_TOALTSTACK)
            {
                altStack.Push(stack.PopItem());
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_FROMALTSTACK)
            {
                if (altStack.Count == 0)
                    throw new ScriptError("altstack underflow");
                stack.PushItem(altStack.Pop());
                offset++;
                instructionPos++;
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
                instructionPos++;
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
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_2OVER)
            {
                if (stack.Count < 4)
                    throw new ScriptError("OP_2OVER stack underflow");
                stack.PushItem(stack.ItemFromTop(4).ToArray());
                stack.PushItem(stack.ItemFromTop(4).ToArray());
                offset++;
                instructionPos++;
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
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_DEPTH)
            {
                stack.PushItem(ScriptNum.Encode(stack.Count));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_PICK)
            {
                var depth = ScriptNum.Decode(stack.PopItem());
                if (depth < 0 || depth >= stack.Count)
                    throw new ScriptError("OP_PICK out of range");
                stack.PushItem(stack.ItemFromTop(depth + 1).ToArray());
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_ROLL)
            {
                stack.RollFromTop(ScriptNum.Decode(stack.PopItem()));
                offset++;
                instructionPos++;
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
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_SWAP)
            {
                var a = stack.PopItem();
                var b = stack.PopItem();
                stack.PushItem(a);
                stack.PushItem(b);
                offset++;
                instructionPos++;
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
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_DUP)
            {
                var item = stack.PopItem();
                stack.PushItem(item);
                stack.PushItem(item.ToArray());
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_IFDUP)
            {
                var item = stack.PeekItem();
                if (ScriptInterpreter.CastToBool(item))
                    stack.PushItem(item.ToArray());
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_NIP)
            {
                var top = stack.PopItem();
                stack.PopItem();
                stack.PushItem(top);
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_OVER)
            {
                if (stack.Count < 2)
                    throw new ScriptError("OP_OVER stack underflow");
                stack.PushItem(stack.ItemFromTop(2).ToArray());
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_SIZE)
            {
                stack.PushItem(ScriptNum.Encode(stack.PeekItem().Length));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_SHA1)
            {
                stack.PushItem(Hash160.Sha1(stack.PopItem()));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_SHA256)
            {
                stack.PushItem(Hash160.Sha256(stack.PopItem()));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_HASH256)
            {
                stack.PushItem(Hash160.Hash256(stack.PopItem()));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_HASH160)
            {
                stack.PushItem(Hash160.Compute(stack.PopItem()));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_RIPEMD160)
            {
                stack.PushItem(Hash160.Ripemd160(stack.PopItem()));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_ADD || opcode == Opcodes.OP_SUB)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(ScriptNum.Encode(opcode == Opcodes.OP_ADD ? aVal + bVal : aVal - bVal));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_1SUB)
            {
                stack.PushItem(ScriptNum.Encode(ScriptNum.Decode(stack.PopItem()) - 1));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_NEGATE)
            {
                stack.PushItem(ScriptNum.Encode(-ScriptNum.Decode(stack.PopItem())));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_NOT)
            {
                stack.PushItem(ScriptInterpreter.EncodeOpN(ScriptInterpreter.CastToBool(stack.PopItem()) ? 0 : 1));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_0NOTEQUAL)
            {
                stack.PushItem(ScriptInterpreter.EncodeOpN(ScriptInterpreter.CastToBool(stack.PopItem()) ? 1 : 0));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_BOOLAND || opcode == Opcodes.OP_BOOLOR)
            {
                var bVal = ScriptInterpreter.CastToBool(stack.PopItem());
                var aVal = ScriptInterpreter.CastToBool(stack.PopItem());
                stack.PushItem(ScriptInterpreter.EncodeOpN(opcode == Opcodes.OP_BOOLAND ? aVal && bVal ? 1 : 0 : aVal || bVal ? 1 : 0));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_MIN || opcode == Opcodes.OP_MAX)
            {
                var bVal = ScriptNum.Decode(stack.PopItem());
                var aVal = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(ScriptNum.Encode(opcode == Opcodes.OP_MIN ? Math.Min(aVal, bVal) : Math.Max(aVal, bVal)));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_EQUAL)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                stack.PushItem(ScriptInterpreter.EncodeOpN(aVal.SequenceEqual(bVal) ? 1 : 0));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_EQUALVERIFY)
            {
                var bVal = stack.PopItem();
                var aVal = stack.PopItem();
                if (!aVal.SequenceEqual(bVal))
                    throw new ScriptError("EQUALVERIFY failed");
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_VERIFY)
            {
                if (!ScriptInterpreter.CastToBool(stack.PopItem()))
                    throw new ScriptError("VERIFY failed");
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_CODESEPARATOR)
            {
                codeSeparatorPos = instrAt;
                offset++;
                instructionPos++;
            }
            else if (opcode is Opcodes.OP_CHECKMULTISIG or Opcodes.OP_CHECKMULTISIGVERIFY)
            {
                throw new ScriptError("CHECKMULTISIG disabled in tapscript");
            }
            else if (opcode == Opcodes.OP_CHECKSIG || opcode == Opcodes.OP_CHECKSIGVERIFY)
            {
                var pubkey = stack.PopItem();
                var signature = stack.PopItem();
                var valid = CheckSchnorrSignature(pubkey, signature, tx, inputIndex, spentPrevouts, annex, tapleafHash, codeSeparatorPos, ref validationBudgetLeft, cache);
                if (opcode == Opcodes.OP_CHECKSIG)
                    stack.PushItem(ScriptInterpreter.EncodeOpN(valid ? 1 : 0));
                else if (!valid)
                    throw new ScriptError("CHECKSIGVERIFY failed");
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_CHECKSIGADD)
            {
                var pubkey = stack.PopItem();
                var nItem = stack.PopItem();
                var signature = stack.PopItem();
                var n = ScriptNum.Decode(nItem);
                var valid = CheckSchnorrSignature(pubkey, signature, tx, inputIndex, spentPrevouts, annex, tapleafHash, codeSeparatorPos, ref validationBudgetLeft, cache);
                stack.PushItem(ScriptNum.Encode(valid ? n + 1 : n));
                offset++;
                instructionPos++;
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
                    stack.PushItem(ScriptInterpreter.EncodeOpN(opcode == Opcodes.OP_NUMEQUAL ? equal ? 1 : 0 : equal ? 0 : 1));
                }
                offset++;
                instructionPos++;
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
                stack.PushItem(ScriptInterpreter.EncodeOpN(result ? 1 : 0));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_WITHIN)
            {
                var maxVal = ScriptNum.Decode(stack.PopItem());
                var minVal = ScriptNum.Decode(stack.PopItem());
                var value = ScriptNum.Decode(stack.PopItem());
                stack.PushItem(ScriptInterpreter.EncodeOpN(minVal <= value && value < maxVal ? 1 : 0));
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_CHECKLOCKTIMEVERIFY)
            {
                CheckLockTimeVerify(stack, tx);
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_CHECKSEQUENCEVERIFY)
            {
                CheckSequenceVerify(stack, tx, inputIndex);
                offset++;
                instructionPos++;
            }
            else if (opcode == Opcodes.OP_NOP)
            {
                offset++;
                instructionPos++;
            }
            else
            {
                throw new ScriptError($"unsupported tapscript opcode 0x{opcode:x2}");
            }
        }

        if (vfExec.Count != 0)
            throw new ScriptError("unbalanced conditional");
    }

    private static bool CheckSchnorrSignature(
        byte[] pubkey,
        byte[] signature,
        Transaction tx,
        int inputIndex,
        IReadOnlyList<ScriptVerify.SpentPrevout> spentPrevouts,
        byte[]? annex,
        byte[] tapleafHash,
        long codeSeparatorPos,
        ref int validationBudgetLeft,
        SighashCache? cache)
    {
        if (pubkey.Length == 0)
            throw new ScriptError("empty pubkey in tapscript checksig");
        if (signature.Length == 0)
            return false;

        ConsumeSigop(ref validationBudgetLeft);
        if (pubkey.Length != 32)
            return true;
        if (signature.Length is not (64 or 65))
            throw new ScriptError("invalid Schnorr signature length");

        var hashType = TaprootSighash.SighashDefault;
        var sig64 = signature;
        if (signature.Length == 65)
        {
            hashType = signature[64];
            if (hashType == TaprootSighash.SighashDefault)
                throw new ScriptError("invalid tap hashtype byte");
            sig64 = signature[..64];
        }

        byte[] message;
        try
        {
            message = TaprootSighash.SignatureHash(
                tx,
                inputIndex,
                spentPrevouts,
                TaprootSighash.TaprootSighashOptions.ScriptPath(hashType, annex, tapleafHash, codeSeparatorPos),
                cache);
        }
        catch (ArgumentException error)
        {
            throw new ScriptError(error.Message);
        }
        return Secp256k1.VerifySchnorrSignature(pubkey, message, sig64);
    }

    private static void ConsumeSigop(ref int validationBudgetLeft)
    {
        validationBudgetLeft -= ValidationWeightPerSigop;
        if (validationBudgetLeft < 0)
            throw new ScriptError("tapscript validation weight exceeded");
    }

    private static bool OpcodeIsSuccess(byte opcode)
    {
        if (opcode is 80 or 98)
            return true;
        if (opcode is >= 126 and <= 129)
            return true;
        if (opcode is >= 131 and <= 134)
            return true;
        if (opcode is >= 137 and <= 138)
            return true;
        if (opcode is >= 141 and <= 142)
            return true;
        if (opcode is >= 149 and <= 153)
            return true;
        return opcode is >= 187 and <= 254;
    }

    private static void CheckLockTimeVerify(ScriptStack stack, Transaction tx)
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

    private static bool TxIsFinalForCltv(Transaction tx) =>
        tx.LockTime == 0 || tx.Inputs.All(input => input.Sequence == SequenceFinal);
}
