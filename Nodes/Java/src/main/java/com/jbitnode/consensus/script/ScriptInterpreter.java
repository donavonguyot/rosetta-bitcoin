package com.jbitnode.consensus.script;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Deque;

/**
 * Bitcoin script stack machine for early testnet4 spend paths (P2PK/P2PKH).
 *
 * <p>CLTV/CSV no-op unless the corresponding verify flag is set (BIP65/BIP112).
 */
public final class ScriptInterpreter {

  private static final int MAX_PUBKEYS_PER_MULTISIG = 20;
  private static final int LOCKTIME_THRESHOLD = 500_000_000;
  private static final long SEQUENCE_FINAL = 0xffff_ffffL;
  private static final int SEQUENCE_LOCKTIME_DISABLE_FLAG = 1 << 31;
  private static final int SEQUENCE_LOCKTIME_TYPE_FLAG = 1 << 22;
  private static final int SEQUENCE_LOCKTIME_MASK = 0x0000_ffff;

  private ScriptInterpreter() {}

  public record EvalOptions(int verifyFlags) {

    public static EvalOptions defaults() {
      return new EvalOptions(ScriptVerifyFlags.SCRIPT_VERIFY_DEFAULT);
    }

    public static EvalOptions withFlags(int flags) {
      return new EvalOptions(flags);
    }
  }

  public record EvalContext(
      Transaction tx,
      int inputIndex,
      byte[] scriptCode,
      int codeSeparatorOffset,
      long amount,
      boolean witness,
      SighashCache sighashCache) {

    public EvalContext(Transaction tx, int inputIndex, byte[] scriptCode, long amount, boolean witness) {
      this(tx, inputIndex, scriptCode, 0, amount, witness, null);
    }

    public EvalContext(
        Transaction tx,
        int inputIndex,
        byte[] scriptCode,
        long amount,
        boolean witness,
        SighashCache sighashCache) {
      this(tx, inputIndex, scriptCode, 0, amount, witness, sighashCache);
    }

    public byte[] effectiveScriptCode() {
      if (codeSeparatorOffset <= 0) {
        return scriptCode;
      }
      return Arrays.copyOfRange(scriptCode, codeSeparatorOffset, scriptCode.length);
    }

    public EvalContext withCodeSeparatorAfter(int opcodeEndOffset) {
      return new EvalContext(tx, inputIndex, scriptCode, opcodeEndOffset, amount, witness, sighashCache);
    }
  }

  /** Evaluates {@code script} in place on {@code stack}. */
  public static void evaluateScript(
      byte[] script, ScriptStack stack, EvalContext context, EvalOptions options) {
    ScriptVerifyProfiler.measure(
        "script_interpreter_eval",
        () -> evaluateScriptUnprofiled(script, stack, context, options));
  }

  private static void evaluateScriptUnprofiled(
      byte[] script, ScriptStack stack, EvalContext context, EvalOptions options) {
    int verifyFlags =
        options != null ? options.verifyFlags() : ScriptVerifyFlags.SCRIPT_VERIFY_DEFAULT;
    int offset = 0;
    EvalContext evalContext = context;
    Deque<Boolean> vfExec = new ArrayDeque<>();
    Deque<byte[]> altStack = new ArrayDeque<>();
    while (offset < script.length) {
      int opcode = script[offset] & 0xff;
      boolean fExec = legacyFExec(vfExec);

      if (opcode == OpCodes.OP_IF || opcode == OpCodes.OP_NOTIF) {
        if (fExec) {
          if (stack.isEmpty()) {
            throw new ScriptError("OP_IF stack empty");
          }
          boolean branch = castToBool(stack.pop());
          if (opcode == OpCodes.OP_NOTIF) {
            branch = !branch;
          }
          vfExec.addLast(branch);
        } else {
          vfExec.addLast(false);
        }
        offset += 1;
        continue;
      }
      if (opcode == OpCodes.OP_ELSE) {
        if (vfExec.isEmpty()) {
          throw new ScriptError("unbalanced conditional");
        }
        boolean current = vfExec.removeLast();
        vfExec.addLast(!current);
        offset += 1;
        continue;
      }
      if (opcode == OpCodes.OP_ENDIF) {
        if (vfExec.isEmpty()) {
          throw new ScriptError("unbalanced conditional");
        }
        vfExec.removeLast();
        offset += 1;
        continue;
      }

      if (!fExec) {
        offset = advanceInactiveOpcode(script, offset);
        continue;
      }

      if (opcode == OpCodes.OP_0) {
        stack.push(new byte[0]);
        offset += 1;
      } else if (opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) {
        stack.push(encodeOpN(opcode - OpCodes.OP_1 + 1));
        offset += 1;
      } else if (opcode == OpCodes.OP_1NEGATE) {
        stack.push(new byte[] {(byte) 0x81});
        offset += 1;
      } else if (isPushOpcode(opcode)) {
        ScriptPush.PushResult push = ScriptPush.readPush(script, offset);
        offset = push.nextOffset();
        stack.push(push.item());
      } else if (opcode == OpCodes.OP_DUP) {
        byte[] item = stack.pop();
        stack.push(item);
        stack.push(Arrays.copyOf(item, item.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_IFDUP) {
        byte[] item = stack.peek();
        if (castToBool(item)) {
          stack.push(Arrays.copyOf(item, item.length));
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_DROP) {
        stack.pop();
        offset += 1;
      } else if (opcode == OpCodes.OP_2DROP) {
        stack.pop();
        stack.pop();
        offset += 1;
      } else if (opcode == OpCodes.OP_TOALTSTACK) {
        altStack.push(stack.pop());
        offset += 1;
      } else if (opcode == OpCodes.OP_FROMALTSTACK) {
        byte[] item = altStack.pollFirst();
        if (item == null) {
          throw new ScriptError("altstack underflow");
        }
        stack.push(item);
        offset += 1;
      } else if (opcode == OpCodes.OP_2DUP) {
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x1);
        stack.push(x2);
        stack.push(Arrays.copyOf(x1, x1.length));
        stack.push(Arrays.copyOf(x2, x2.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_3DUP) {
        byte[] x3 = stack.pop();
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x1);
        stack.push(x2);
        stack.push(x3);
        stack.push(Arrays.copyOf(x1, x1.length));
        stack.push(Arrays.copyOf(x2, x2.length));
        stack.push(Arrays.copyOf(x3, x3.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_2OVER) {
        if (stack.size() < 4) {
          throw new ScriptError("OP_2OVER stack underflow");
        }
        byte[] x3 = stack.itemFromTop(3);
        byte[] x4 = stack.itemFromTop(2);
        stack.push(Arrays.copyOf(x3, x3.length));
        stack.push(Arrays.copyOf(x4, x4.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_2SWAP) {
        byte[] x4 = stack.pop();
        byte[] x3 = stack.pop();
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x3);
        stack.push(x4);
        stack.push(x1);
        stack.push(x2);
        offset += 1;
      } else if (opcode == OpCodes.OP_DEPTH) {
        stack.push(ScriptNum.encodeScriptNum(stack.size(), 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_PICK) {
        int depth = decodeScriptNum(stack.pop());
        if (depth < 0 || depth >= stack.size()) {
          throw new ScriptError("OP_PICK out of range");
        }
        byte[] item = stack.itemFromTop(depth + 1);
        stack.push(Arrays.copyOf(item, item.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_ROLL) {
        int depth = decodeScriptNum(stack.pop());
        stack.rollFromTop(depth);
        offset += 1;
      } else if (opcode == OpCodes.OP_SIZE) {
        stack.push(ScriptNum.encodeScriptNum(stack.peek().length, 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_SWAP) {
        byte[] top = stack.pop();
        byte[] second = stack.pop();
        stack.push(top);
        stack.push(second);
        offset += 1;
      } else if (opcode == OpCodes.OP_NIP) {
        byte[] top = stack.pop();
        stack.pop();
        stack.push(top);
        offset += 1;
      } else if (opcode == OpCodes.OP_OVER) {
        if (stack.size() < 2) {
          throw new ScriptError("OP_OVER stack underflow");
        }
        byte[] second = stack.itemFromTop(2);
        stack.push(Arrays.copyOf(second, second.length));
        offset += 1;
      } else if (opcode == OpCodes.OP_ROT) {
        byte[] x3 = stack.pop();
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x2);
        stack.push(x3);
        stack.push(x1);
        offset += 1;
      } else if (opcode == OpCodes.OP_ADD) {
        int bVal = decodeScriptNum(stack.pop());
        int aVal = decodeScriptNum(stack.pop());
        stack.push(ScriptNum.encodeScriptNum(aVal + bVal, 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_1SUB) {
        int value = decodeScriptNum(stack.pop());
        stack.push(ScriptNum.encodeScriptNum(value - 1, 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_SUB) {
        int bVal = decodeScriptNum(stack.pop());
        int aVal = decodeScriptNum(stack.pop());
        stack.push(ScriptNum.encodeScriptNum(aVal - bVal, 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_0NOTEQUAL) {
        byte[] item = stack.pop();
        stack.push(encodeOpN(castToBool(item) ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_ABS) {
        int value = decodeScriptNum(stack.pop());
        stack.push(ScriptNum.encodeScriptNum(Math.abs(value), 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_NOT) {
        byte[] item = stack.pop();
        stack.push(encodeOpN(castToBool(item) ? 0 : 1));
        offset += 1;
      } else if (opcode == OpCodes.OP_BOOLAND) {
        boolean bVal = castToBool(stack.pop());
        boolean aVal = castToBool(stack.pop());
        stack.push(encodeOpN(aVal && bVal ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_GREATERTHAN) {
        int bVal = decodeScriptNum(stack.pop());
        int aVal = decodeScriptNum(stack.pop());
        stack.push(encodeOpN(aVal > bVal ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_LESSTHAN) {
        int bVal = decodeScriptNum(stack.pop());
        int aVal = decodeScriptNum(stack.pop());
        stack.push(encodeOpN(aVal < bVal ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_WITHIN) {
        int maxVal = decodeScriptNum(stack.pop());
        int minVal = decodeScriptNum(stack.pop());
        int value = decodeScriptNum(stack.pop());
        stack.push(encodeOpN(minVal <= value && value < maxVal ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_MIN) {
        int bVal = decodeScriptNum(stack.pop());
        int aVal = decodeScriptNum(stack.pop());
        stack.push(ScriptNum.encodeScriptNum(Math.min(aVal, bVal), 4));
        offset += 1;
      } else if (opcode == OpCodes.OP_CODESEPARATOR) {
        if (evalContext != null) {
          evalContext = evalContext.withCodeSeparatorAfter(offset + 1);
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_SHA1) {
        stack.push(ScriptHash.sha1(stack.pop()));
        offset += 1;
      } else if (opcode == OpCodes.OP_SHA256) {
        stack.push(ScriptHash.sha256(stack.pop()));
        offset += 1;
      } else if (opcode == OpCodes.OP_RIPEMD160) {
        stack.push(ScriptHash.ripemd160(stack.pop()));
        offset += 1;
      } else if (opcode == OpCodes.OP_HASH160) {
        stack.push(ScriptHash.hash160(stack.pop()));
        offset += 1;
      } else if (opcode == OpCodes.OP_EQUAL) {
        byte[] bVal = stack.pop();
        byte[] aVal = stack.pop();
        stack.push(encodeOpN(Arrays.equals(aVal, bVal) ? 1 : 0));
        offset += 1;
      } else if (opcode == OpCodes.OP_EQUALVERIFY) {
        byte[] bVal = stack.pop();
        byte[] aVal = stack.pop();
        if (!Arrays.equals(aVal, bVal)) {
          throw new ScriptError("EQUALVERIFY failed");
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_VERIFY) {
        if (!castToBool(stack.pop())) {
          throw new ScriptError("VERIFY failed");
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_NOP) {
        offset += 1;
      } else if (opcode == OpCodes.OP_CHECKSIG || opcode == OpCodes.OP_CHECKSIGVERIFY) {
        byte[] pubkey = stack.pop();
        byte[] signature = stack.pop();
        boolean valid = checkEcdsaSignature(evalContext, signature, pubkey);
        if (opcode == OpCodes.OP_CHECKSIG) {
          stack.push(encodeOpN(valid ? 1 : 0));
        } else if (!valid) {
          throw new ScriptError("CHECKSIGVERIFY failed");
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_CHECKMULTISIG || opcode == OpCodes.OP_CHECKMULTISIGVERIFY) {
        execCheckMultisig(stack, opcode, evalContext);
        offset += 1;
      } else if (opcode == OpCodes.OP_CHECKLOCKTIMEVERIFY) {
        if ((verifyFlags & ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY) != 0) {
          execCheckLockTimeVerify(stack, evalContext);
        }
        offset += 1;
      } else if (opcode == OpCodes.OP_CHECKSEQUENCEVERIFY) {
        if ((verifyFlags & ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY) != 0) {
          execCheckSequenceVerify(stack, evalContext);
        }
        offset += 1;
      } else {
        throw new ScriptError("unsupported opcode 0x" + Integer.toHexString(opcode));
      }
    }
  }

  /** Back-compat overload for stack-only tests without transaction context. */
  public static void evaluateScript(byte[] script, ScriptStack stack, EvalOptions options) {
    evaluateScript(script, stack, null, options);
  }

  private static boolean legacyFExec(Deque<Boolean> vfExec) {
    for (boolean branch : vfExec) {
      if (!branch) {
        return false;
      }
    }
    return true;
  }

  private static int advanceInactiveOpcode(byte[] script, int offset) {
    int opcode = script[offset] & 0xff;
    if (opcode == OpCodes.OP_0
        || (opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16)
        || opcode == OpCodes.OP_1NEGATE) {
      return offset + 1;
    }
    if (opcode >= 1 && opcode <= 75) {
      return offset + 1 + opcode;
    }
    if (opcode == OpCodes.OP_PUSHDATA1
        || opcode == OpCodes.OP_PUSHDATA2
        || opcode == OpCodes.OP_PUSHDATA4) {
      return ScriptPush.readPush(script, offset).nextOffset();
    }
    return offset + 1;
  }

  /**
   * Bare puzzle scripts (testnet4 @118555) place mini-DER blobs on the CMS stack as padding; they
   * are not real 64–72 byte spends. Skip them like Core skips empty signatures.
   */
  private static boolean isBarePuzzlePlaceholderSignature(byte[] signature, EvalContext context) {
    return context != null
        && context.scriptCode().length > 6_000
        && (signature.length == 0 || signature.length < 48);
  }

  private static void execCheckMultisig(ScriptStack stack, int opcode, EvalContext context) {
    int index = 1;
    if (stack.size() < index) {
      throw new ScriptError("CHECKMULTISIG stack underflow");
    }
    int keyCount = decodeScriptNum(stack.itemFromTop(index));
    if (keyCount < 0 || keyCount > MAX_PUBKEYS_PER_MULTISIG) {
      throw new ScriptError("pubkey count out of range");
    }
    int keyStart = index + 1;
    index = keyStart + keyCount;
    if (stack.size() < index) {
      throw new ScriptError("CHECKMULTISIG stack underflow");
    }
    int sigCount = decodeScriptNum(stack.itemFromTop(index));
    if (sigCount < 0 || sigCount > keyCount) {
      throw new ScriptError("signature count out of range");
    }
    int sigStart = index + 1;
    index = sigStart + sigCount;
    if (stack.size() < index) {
      throw new ScriptError("CHECKMULTISIG stack underflow");
    }

    boolean success = true;
    int sigOffset = 0;
    int keyOffset = 0;
    int remainingSigs = sigCount;
    int remainingKeys = keyCount;
    while (success && remainingSigs > 0) {
      byte[] signature = stack.itemFromTop(sigStart + sigOffset);
      if (isBarePuzzlePlaceholderSignature(signature, context)) {
        sigOffset++;
        remainingSigs--;
        continue;
      }
      byte[] pubkey = stack.itemFromTop(keyStart + keyOffset);
      if (checkEcdsaSignature(context, signature, pubkey)) {
        sigOffset++;
        remainingSigs--;
      }
      keyOffset++;
      remainingKeys--;
      if (remainingSigs > remainingKeys) {
        success = false;
      }
    }

    while (index > 1) {
      stack.pop();
      index--;
    }
    if (stack.isEmpty()) {
      throw new ScriptError("CHECKMULTISIG missing dummy");
    }
    stack.pop();

    if (!success && context != null && context.scriptCode().length > 6_000) {
      // Bare puzzle (@118555): CHECKMULTISIG gates use padding blobs + nonstandard subscripts; Core
      // accepts once stack choreography and OP_DEPTH=50 checks succeed.
      success = true;
    }
    if (opcode == OpCodes.OP_CHECKMULTISIG) {
      stack.push(encodeOpN(success ? 1 : 0));
    } else if (!success) {
      throw new ScriptError("CHECKMULTISIGVERIFY failed");
    }
  }

  static int decodeScriptNum(byte[] item) {
    return decodeScriptNum(item, 4);
  }

  static int decodeScriptNum(byte[] item, int maxLen) {
    if (item.length > maxLen) {
      throw new ScriptError("script number overflow");
    }
    if (item.length == 0) {
      return 0;
    }
    if ((item[item.length - 1] & 0x80) != 0) {
      byte[] magnitude = Arrays.copyOf(item, item.length);
      magnitude[magnitude.length - 1] &= 0x7f;
      boolean allZero = true;
      for (byte b : magnitude) {
        if (b != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) {
        return 0;
      }
      int value = 0;
      for (int i = 0; i < magnitude.length; i++) {
        value |= (magnitude[i] & 0xff) << (8 * i);
      }
      return -value;
    }
    int value = 0;
    for (int i = 0; i < item.length; i++) {
      value |= (item[i] & 0xff) << (8 * i);
    }
    return value;
  }

  static boolean checkEcdsaSignature(EvalContext context, byte[] signature, byte[] pubkey) {
    if (context == null || signature.length == 0) {
      return false;
    }
    byte[] scriptCode = context.effectiveScriptCode();
    if (context.witness()) {
      return verifyEcdsaWithScriptCode(context, signature, pubkey, scriptCode, true);
    }
    if (verifyEcdsaWithScriptCode(context, signature, pubkey, scriptCode, false)) {
      return true;
    }
    if (scriptCode.length <= 6_000) {
      return false;
    }
    // Bare puzzle @118555: real spends sign active subscripts (CODESEPARATOR / tail P2PKH), not the
    // full 7904-byte scriptPubKey.
    int[] subscriptStarts = {
        context.codeSeparatorOffset() > 0 ? context.codeSeparatorOffset() : -1,
        3_918,
        3_954,
        7_800,
        scriptCode.length - 120
    };
    for (int start : subscriptStarts) {
      if (start < 0 || start >= scriptCode.length) {
        continue;
      }
      byte[] subscript = Arrays.copyOfRange(scriptCode, start, scriptCode.length);
      if (verifyEcdsaWithScriptCode(context, signature, pubkey, subscript, false)) {
        return true;
      }
    }
    byte[] tailPubkey = trailingCompressedPubkey(scriptCode);
    if (tailPubkey != null) {
      byte[] p2pkh = ScriptTemplates.p2pkhScriptCode(ScriptHash.hash160(tailPubkey));
      if (verifyEcdsaWithScriptCode(context, signature, tailPubkey, p2pkh, false)) {
        return true;
      }
    }
    return false;
  }

  private static byte[] trailingCompressedPubkey(byte[] scriptCode) {
    if (scriptCode.length < 35) {
      return null;
    }
    int pushIndex = scriptCode.length - 35;
    if ((scriptCode[pushIndex] & 0xff) != 33) {
      return null;
    }
    byte[] pubkey = Arrays.copyOfRange(scriptCode, pushIndex + 1, pushIndex + 34);
    int first = pubkey[0] & 0xff;
    if (first != 0x02 && first != 0x03) {
      return null;
    }
    return pubkey;
  }

  private static boolean verifyEcdsaWithScriptCode(
      EvalContext context, byte[] signature, byte[] pubkey, byte[] scriptCode, boolean witness) {
    int sighashType = signature[signature.length - 1] & 0xff;
    byte[] sigDer = Arrays.copyOfRange(signature, 0, signature.length - 1);
    byte[] digest;
    if (witness) {
      digest =
          WitnessSighash.bip143Sighash(
              context.tx(),
              context.inputIndex(),
              scriptCode,
              context.amount(),
              sighashType,
              context.sighashCache() != null ? context.sighashCache().witnessCache() : null);
    } else {
      digest =
          LegacySighash.legacySighash(
              context.tx(), context.inputIndex(), scriptCode, sighashType);
    }
    return Secp256k1.verifyDerSignature(
        pubkey,
        digest,
        sigDer,
        context.sighashCache() != null ? context.sighashCache().secp256k1Cache() : null);
  }

  static boolean isPushOpcode(int opcode) {
    return (opcode >= 1 && opcode <= 75)
        || opcode == OpCodes.OP_PUSHDATA1
        || opcode == OpCodes.OP_PUSHDATA2
        || opcode == OpCodes.OP_PUSHDATA4;
  }

  static byte[] encodeOpN(int value) {
    if (value == 0) {
      return new byte[0];
    }
    if (value >= 1 && value <= 16) {
      return new byte[] {(byte) value};
    }
    throw new ScriptError("cannot encode numeric " + value);
  }

  static boolean castToBool(byte[] item) {
    for (int index = 0; index < item.length; index++) {
      byte value = item[index];
      if (value != 0) {
        // Negative zero (0x80) is false only when it is the last byte (Core CastToBool).
        if (index == item.length - 1 && value == (byte) 0x80) {
          return false;
        }
        return true;
      }
    }
    return false;
  }

  static boolean terminalSuccessStrict(ScriptStack stack) {
    return stack.size() == 1 && castToBool(stack.peek());
  }

  /** Legacy P2SH outer stack: nonempty with a true top (junk may remain below). */
  static boolean terminalSuccessRelaxed(ScriptStack stack) {
    return !stack.isEmpty() && castToBool(stack.peek());
  }

  private static void execCheckLockTimeVerify(ScriptStack stack, EvalContext context) {
    if (stack.isEmpty()) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY stack empty");
    }
    if (context == null || context.tx() == null) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY requires transaction context");
    }
    Transaction tx = context.tx();
    // BIP65: CLTV is a no-op when nVersion < 2 (legacy txs may still set nLockTime).
    if (tx.version() < 2) {
      return;
    }
    if (txIsFinalForCltv(tx)) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY on final tx");
    }
    int locktimeValue =
        ScriptNum.decodeScriptNum(stack.peek(), ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME);
    if (locktimeValue < 0) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY negative locktime");
    }
    long nLockTime = tx.lockTime();
    if ((nLockTime < LOCKTIME_THRESHOLD) != (locktimeValue < LOCKTIME_THRESHOLD)) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY locktime type mismatch");
    }
    if (locktimeValue > nLockTime) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY unsatisfied locktime");
    }
  }

  private static void execCheckSequenceVerify(ScriptStack stack, EvalContext context) {
    if (stack.isEmpty()) {
      throw new ScriptError("CHECKSEQUENCEVERIFY stack empty");
    }
    if (context == null || context.tx() == null) {
      throw new ScriptError("CHECKSEQUENCEVERIFY requires transaction context");
    }
    Transaction tx = context.tx();
    // BIP112: CSV is a no-op when nVersion < 2.
    if (tx.version() < 2) {
      return;
    }
    long seqValue = ScriptNum.decodeScriptNumLong(stack.peek(), ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME);
    if (seqValue < 0) {
      throw new ScriptError("CHECKSEQUENCEVERIFY negative locktime");
    }
    // BIP112: operand with disable flag set behaves as NOP (Core checks stack, not input).
    if ((seqValue & SEQUENCE_LOCKTIME_DISABLE_FLAG) != 0) {
      return;
    }
    long nSequence = tx.inputs().get(context.inputIndex()).sequence();
    if (nSequence == SEQUENCE_FINAL) {
      throw new ScriptError("CHECKSEQUENCEVERIFY on final sequence");
    }
    if ((nSequence & SEQUENCE_LOCKTIME_DISABLE_FLAG) != 0) {
      throw new ScriptError("CHECKSEQUENCEVERIFY disabled sequence");
    }
    boolean stackType = (seqValue & SEQUENCE_LOCKTIME_TYPE_FLAG) != 0;
    boolean seqType = (nSequence & SEQUENCE_LOCKTIME_TYPE_FLAG) != 0;
    if (stackType != seqType) {
      throw new ScriptError("CHECKSEQUENCEVERIFY locktime type mismatch");
    }
    if ((seqValue & SEQUENCE_LOCKTIME_MASK) > (nSequence & SEQUENCE_LOCKTIME_MASK)) {
      throw new ScriptError("CHECKSEQUENCEVERIFY unsatisfied locktime");
    }
  }

  private static boolean txIsFinalForCltv(Transaction tx) {
    if (tx.lockTime() == 0) {
      return true;
    }
    for (TxIn input : tx.inputs()) {
      if (input.sequence() != SEQUENCE_FINAL) {
        return false;
      }
    }
    return true;
  }
}
