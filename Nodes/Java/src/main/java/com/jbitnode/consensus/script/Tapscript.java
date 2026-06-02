package com.jbitnode.consensus.script;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.List;

/** BIP342 tapscript evaluation for P2TR script-path spends. */
final class Tapscript {

  static final int MAX_TAPSCRIPT_STACK_ELEMENTS = 1000;
  static final int MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS = 520;
  static final int VALIDATION_WEIGHT_OFFSET = 50;
  static final int VALIDATION_WEIGHT_PER_SIGOP = 50;

  private static final int LOCKTIME_THRESHOLD = 500_000_000;
  private static final long SEQUENCE_FINAL = 0xffff_ffffL;
  private static final long SEQUENCE_LOCKTIME_DISABLE_FLAG = 1L << 31;
  private static final long SEQUENCE_LOCKTIME_TYPE_FLAG = 1L << 22;
  private static final long SEQUENCE_LOCKTIME_MASK = 0x0000_ffffL;

  private Tapscript() {}

  static boolean prescanOpSuccess(byte[] script) {
    int offset = 0;
    while (offset < script.length) {
      int opcode = script[offset] & 0xff;
      if (opcode == OpCodes.OP_0) {
        offset += 1;
        continue;
      }
      if ((opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) || opcode == OpCodes.OP_1NEGATE) {
        offset += 1;
        continue;
      }
      if (opcode >= 1 && opcode <= 75) {
        offset += 1 + opcode;
        continue;
      }
      if (opcode == OpCodes.OP_PUSHDATA1
          || opcode == OpCodes.OP_PUSHDATA2
          || opcode == OpCodes.OP_PUSHDATA4) {
        try {
          offset = ScriptPush.readPush(script, offset).nextOffset();
        } catch (ScriptError error) {
          return false;
        }
        continue;
      }
      if (opcodeIsSuccess(opcode)) {
        return true;
      }
      offset += 1;
    }
    return false;
  }

  static void evaluate(
      byte[] script,
      ScriptStack stack,
      Transaction tx,
      int inputIndex,
      byte[] tapleafDigest,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      byte[] annex,
      int[] validationBudgetLeft) {
    evaluate(
        script,
        stack,
        tx,
        inputIndex,
        tapleafDigest,
        spentPrevouts,
        annex,
        validationBudgetLeft,
        null);
  }

  static void evaluate(
      byte[] script,
      ScriptStack stack,
      Transaction tx,
      int inputIndex,
      byte[] tapleafDigest,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      byte[] annex,
      int[] validationBudgetLeft,
      SighashCache sighashCache) {
    if (prescanOpSuccess(script)) {
      return;
    }

    long codeseparatorPos = 0xffff_ffffL;
    int instructionPos = 0;
    int offset = 0;
    Deque<Boolean> vfExec = new ArrayDeque<>();
    Deque<byte[]> altStack = new ArrayDeque<>();

    while (offset < script.length) {
      int instrAt = instructionPos;
      int opcode = script[offset] & 0xff;
      boolean fExec = allTrue(vfExec);

      if (opcode == OpCodes.OP_IF || opcode == OpCodes.OP_NOTIF) {
        if (fExec) {
          if (stack.isEmpty()) {
            throw new ScriptError("OP_IF stack empty");
          }
          boolean branch = ScriptInterpreter.castToBool(stack.pop());
          if (opcode == OpCodes.OP_NOTIF) {
            branch = !branch;
          }
          vfExec.addLast(branch);
        } else {
          vfExec.addLast(false);
        }
        offset += 1;
        instructionPos += 1;
        continue;
      }
      if (opcode == OpCodes.OP_ELSE) {
        if (vfExec.isEmpty()) {
          throw new ScriptError("unbalanced conditional");
        }
        boolean current = vfExec.removeLast();
        vfExec.addLast(!current);
        offset += 1;
        instructionPos += 1;
        continue;
      }
      if (opcode == OpCodes.OP_ENDIF) {
        if (vfExec.isEmpty()) {
          throw new ScriptError("unbalanced conditional");
        }
        vfExec.removeLast();
        offset += 1;
        instructionPos += 1;
        continue;
      }

      if (!fExec) {
        offset = advanceOpcode(script, offset);
        instructionPos += 1;
        continue;
      }

      if (opcode == OpCodes.OP_0) {
        stack.push(new byte[0]);
        offset += 1;
        instructionPos += 1;
      } else if (opcode >= OpCodes.OP_1 && opcode <= OpCodes.OP_16) {
        stack.push(ScriptInterpreter.encodeOpN(opcode - OpCodes.OP_1 + 1));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_1NEGATE) {
        stack.push(new byte[] {(byte) 0x81});
        offset += 1;
        instructionPos += 1;
      } else if (ScriptInterpreter.isPushOpcode(opcode)) {
        ScriptPush.PushResult push = ScriptPush.readPush(script, offset);
        offset = push.nextOffset();
        stack.push(push.item());
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_DROP) {
        stack.pop();
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_2DROP) {
        stack.pop();
        stack.pop();
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_TOALTSTACK) {
        altStack.push(stack.pop());
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_FROMALTSTACK) {
        byte[] item = altStack.pollFirst();
        if (item == null) {
          throw new ScriptError("altstack underflow");
        }
        stack.push(item);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_2DUP) {
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x1);
        stack.push(x2);
        stack.push(Arrays.copyOf(x1, x1.length));
        stack.push(Arrays.copyOf(x2, x2.length));
        offset += 1;
        instructionPos += 1;
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
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_2OVER) {
        if (stack.size() < 4) {
          throw new ScriptError("OP_2OVER stack underflow");
        }
        byte[] x3 = stack.itemFromTop(3);
        byte[] x4 = stack.itemFromTop(2);
        stack.push(Arrays.copyOf(x3, x3.length));
        stack.push(Arrays.copyOf(x4, x4.length));
        offset += 1;
        instructionPos += 1;
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
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_DEPTH) {
        stack.push(ScriptNum.encodeScriptNum(stack.size(), 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_PICK) {
        int depth = ScriptNum.decodeScriptNum(stack.pop(), 4);
        if (depth < 0 || depth >= stack.size()) {
          throw new ScriptError("OP_PICK out of range");
        }
        stack.push(Arrays.copyOf(stack.itemFromTop(depth + 1), stack.itemFromTop(depth + 1).length));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_TUCK) {
        if (stack.size() < 2) {
          throw new ScriptError("OP_TUCK stack underflow");
        }
        // Core inserts a copy of the top item before the second-from-top (x1 x0 -> x0 x1 x0).
        byte[] top = stack.pop();
        byte[] second = stack.pop();
        stack.push(Arrays.copyOf(top, top.length));
        stack.push(second);
        stack.push(top);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_ROLL) {
        int depth = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.rollFromTop(depth);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_ROT) {
        byte[] x3 = stack.pop();
        byte[] x2 = stack.pop();
        byte[] x1 = stack.pop();
        stack.push(x2);
        stack.push(x3);
        stack.push(x1);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_SWAP) {
        byte[] a = stack.pop();
        byte[] b = stack.pop();
        stack.push(a);
        stack.push(b);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_DUP) {
        byte[] item = stack.pop();
        stack.push(item);
        stack.push(Arrays.copyOf(item, item.length));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_IFDUP) {
        byte[] item = stack.peek();
        if (ScriptInterpreter.castToBool(item)) {
          stack.push(Arrays.copyOf(item, item.length));
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_NIP) {
        byte[] top = stack.pop();
        stack.pop();
        stack.push(top);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_OVER) {
        if (stack.size() < 2) {
          throw new ScriptError("OP_OVER stack underflow");
        }
        byte[] second = stack.itemFromTop(2);
        stack.push(Arrays.copyOf(second, second.length));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_SIZE) {
        stack.push(ScriptNum.encodeScriptNum(stack.peek().length, 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_SHA1) {
        stack.push(ScriptHash.sha1(stack.pop()));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_SHA256) {
        stack.push(ScriptHash.sha256(stack.pop()));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_HASH256) {
        stack.push(ScriptHash.hash256(stack.pop()));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_HASH160) {
        stack.push(ScriptHash.hash160(stack.pop()));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_ADD) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(aVal + bVal, 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_SUB) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(aVal - bVal, 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_1SUB) {
        int value = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(value - 1, 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_NEGATE) {
        int value = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(-value, 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_NOT) {
        boolean value = ScriptInterpreter.castToBool(stack.pop());
        stack.push(ScriptInterpreter.encodeOpN(value ? 0 : 1));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_0NOTEQUAL) {
        byte[] item = stack.pop();
        stack.push(ScriptInterpreter.encodeOpN(ScriptInterpreter.castToBool(item) ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_BOOLAND) {
        boolean bVal = ScriptInterpreter.castToBool(stack.pop());
        boolean aVal = ScriptInterpreter.castToBool(stack.pop());
        stack.push(ScriptInterpreter.encodeOpN(aVal && bVal ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_BOOLOR) {
        boolean bVal = ScriptInterpreter.castToBool(stack.pop());
        boolean aVal = ScriptInterpreter.castToBool(stack.pop());
        stack.push(ScriptInterpreter.encodeOpN(aVal || bVal ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_MIN) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(Math.min(aVal, bVal), 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_MAX) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptNum.encodeScriptNum(Math.max(aVal, bVal), 4));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_EQUAL) {
        byte[] bVal = stack.pop();
        byte[] aVal = stack.pop();
        stack.push(ScriptInterpreter.encodeOpN(Arrays.equals(aVal, bVal) ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_EQUALVERIFY) {
        byte[] bVal = stack.pop();
        byte[] aVal = stack.pop();
        if (!Arrays.equals(aVal, bVal)) {
          throw new ScriptError("EQUALVERIFY failed");
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_VERIFY) {
        if (!ScriptInterpreter.castToBool(stack.pop())) {
          throw new ScriptError("VERIFY failed");
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CODESEPARATOR) {
        codeseparatorPos = instrAt;
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CHECKMULTISIG || opcode == OpCodes.OP_CHECKMULTISIGVERIFY) {
        throw new ScriptError("CHECKMULTISIG disabled in tapscript");
      } else if (opcode == OpCodes.OP_NOP) {
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CHECKSIG || opcode == OpCodes.OP_CHECKSIGVERIFY) {
        byte[] pubkey = stack.pop();
        byte[] signature = stack.pop();
        if (pubkey.length == 0) {
          throw new ScriptError("empty pubkey in tapscript checksig");
        }
        if (pubkey.length != 32) {
          if (signature.length == 0) {
            if (opcode == OpCodes.OP_CHECKSIGVERIFY) {
              throw new ScriptError("CHECKSIGVERIFY failed");
            }
            stack.push(new byte[0]);
          } else {
            consumeSigopIfNonempty(signature, validationBudgetLeft);
            if (opcode == OpCodes.OP_CHECKSIG) {
              stack.push(ScriptInterpreter.encodeOpN(1));
            }
          }
          offset += 1;
          instructionPos += 1;
          continue;
        }
        boolean valid = false;
        if (signature.length > 0) {
          consumeSigopIfNonempty(signature, validationBudgetLeft);
          valid =
              verifySchnorrSignature(
                  pubkey,
                  signature,
                  tx,
                  inputIndex,
                  spentPrevouts,
                  annex,
                  tapleafDigest,
                  codeseparatorPos,
                  sighashCache);
        }
        if (opcode == OpCodes.OP_CHECKSIG) {
          stack.push(ScriptInterpreter.encodeOpN(valid ? 1 : 0));
        } else if (!valid) {
          throw new ScriptError("CHECKSIGVERIFY failed");
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CHECKSIGADD) {
        byte[] pubkey = stack.pop();
        byte[] nItem = stack.pop();
        byte[] signature = stack.pop();
        if (pubkey.length == 0) {
          throw new ScriptError("empty pubkey in tapscript checksigadd");
        }
        int n = ScriptNum.decodeScriptNum(nItem, 4);
        if (pubkey.length != 32) {
          if (signature.length > 0) {
            consumeSigopIfNonempty(signature, validationBudgetLeft);
            stack.push(ScriptNum.encodeScriptNum(n + 1, 4));
          } else {
            stack.push(ScriptNum.encodeScriptNum(n, 4));
          }
          offset += 1;
          instructionPos += 1;
          continue;
        }
        if (signature.length == 0) {
          stack.push(ScriptNum.encodeScriptNum(n, 4));
        } else {
          consumeSigopIfNonempty(signature, validationBudgetLeft);
          boolean valid =
              verifySchnorrSignature(
                  pubkey,
                  signature,
                  tx,
                  inputIndex,
                  spentPrevouts,
                  annex,
                  tapleafDigest,
                  codeseparatorPos,
                  sighashCache);
          stack.push(ScriptNum.encodeScriptNum(valid ? n + 1 : n, 4));
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_NUMEQUAL || opcode == OpCodes.OP_NUMNOTEQUAL) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        boolean result = opcode == OpCodes.OP_NUMEQUAL ? aVal == bVal : aVal != bVal;
        stack.push(ScriptInterpreter.encodeOpN(result ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_NUMEQUALVERIFY) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        if (aVal != bVal) {
          throw new ScriptError("NUMEQUALVERIFY failed");
        }
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_LESSTHAN
          || opcode == OpCodes.OP_GREATERTHAN
          || opcode == OpCodes.OP_LESSTHANOREQUAL
          || opcode == OpCodes.OP_GREATERTHANOREQUAL) {
        int bVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int aVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        boolean result =
            switch (opcode) {
              case OpCodes.OP_LESSTHAN -> aVal < bVal;
              case OpCodes.OP_GREATERTHAN -> aVal > bVal;
              case OpCodes.OP_LESSTHANOREQUAL -> aVal <= bVal;
              default -> aVal >= bVal;
            };
        stack.push(ScriptInterpreter.encodeOpN(result ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_WITHIN) {
        int maxVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int minVal = ScriptNum.decodeScriptNum(stack.pop(), 4);
        int value = ScriptNum.decodeScriptNum(stack.pop(), 4);
        stack.push(ScriptInterpreter.encodeOpN(minVal <= value && value < maxVal ? 1 : 0));
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CHECKLOCKTIMEVERIFY) {
        execCheckLockTimeVerify(stack, tx);
        offset += 1;
        instructionPos += 1;
      } else if (opcode == OpCodes.OP_CHECKSEQUENCEVERIFY) {
        execCheckSequenceVerify(stack, tx, inputIndex);
        offset += 1;
        instructionPos += 1;
      } else {
        throw new ScriptError("unsupported tapscript opcode 0x" + Integer.toHexString(opcode));
      }
    }
  }

  private static boolean allTrue(Deque<Boolean> values) {
    for (Boolean value : values) {
      if (!value) {
        return false;
      }
    }
    return true;
  }

  private static boolean opcodeIsSuccess(int opcode) {
    if (opcode == 80 || opcode == 98) {
      return true;
    }
    if (opcode >= 126 && opcode <= 129) {
      return true;
    }
    if (opcode >= 131 && opcode <= 134) {
      return true;
    }
    if (opcode >= 137 && opcode <= 138) {
      return true;
    }
    if (opcode >= 141 && opcode <= 142) {
      return true;
    }
    if (opcode >= 149 && opcode <= 153) {
      return true;
    }
    if (opcode >= 187 && opcode <= 254) {
      return true;
    }
    return false;
  }

  private static int advanceOpcode(byte[] script, int offset) {
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

  private static boolean consumeSigopIfNonempty(byte[] signature, int[] validationBudgetLeft) {
    if (signature.length == 0) {
      return false;
    }
    validationBudgetLeft[0] -= VALIDATION_WEIGHT_PER_SIGOP;
    if (validationBudgetLeft[0] < 0) {
      throw new ScriptError("tapscript validation weight exceeded");
    }
    return true;
  }

  private static boolean verifySchnorrSignature(
      byte[] pubkey,
      byte[] signature,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      byte[] annex,
      byte[] tapleafDigest,
      long codeseparatorPos,
      SighashCache sighashCache) {
    if (signature.length == 0) {
      return false;
    }
    int hashType = TaprootSighash.TAPROOT_SIGHASH_DEFAULT;
    byte[] sig64 = signature;
    if (signature.length == 65) {
      hashType = signature[64] & 0xff;
      if (hashType == TaprootSighash.TAPROOT_SIGHASH_DEFAULT) {
        throw new ScriptError("invalid tap hashtype byte");
      }
      sig64 = Arrays.copyOfRange(signature, 0, 64);
    } else if (signature.length != 64) {
      throw new ScriptError("invalid Schnorr signature length");
    }
    byte[] digest;
    try {
      digest =
          TaprootSighash.taprootSignatureHash(
              tx,
              inputIndex,
              spentPrevouts,
              new TaprootSighash.TaprootSighashOptions(
                      hashType, annex, 1, tapleafDigest, codeseparatorPos),
                  sighashCache != null ? sighashCache.taprootCache() : null);
    } catch (IllegalArgumentException error) {
      throw new ScriptError(error.getMessage());
    }
    return Secp256k1.verifySchnorrSignature(
        pubkey,
        digest,
        sig64,
        sighashCache != null ? sighashCache.secp256k1Cache() : null);
  }

  private static void execCheckLockTimeVerify(ScriptStack stack, Transaction tx) {
    if (stack.isEmpty()) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY stack empty");
    }
    // BIP65: CLTV is a no-op when nVersion < 2 (legacy txs may still set nLockTime).
    if (tx.version() < 2) {
      return;
    }
    if (txIsFinalForCltv(tx)) {
      throw new ScriptError("CHECKLOCKTIMEVERIFY on final tx");
    }
    long locktimeValue =
        ScriptNum.decodeScriptNumLong(stack.peek(), ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME);
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

  private static void execCheckSequenceVerify(ScriptStack stack, Transaction tx, int inputIndex) {
    if (stack.isEmpty()) {
      throw new ScriptError("CHECKSEQUENCEVERIFY stack empty");
    }
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
    long nSequence = tx.inputs().get(inputIndex).sequence();
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
