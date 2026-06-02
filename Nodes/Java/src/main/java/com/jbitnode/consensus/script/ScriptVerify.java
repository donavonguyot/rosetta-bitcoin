package com.jbitnode.consensus.script;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.util.Hex;
import java.util.Arrays;
import java.util.List;

public final class ScriptVerify {
  private ScriptVerify() {}

  static final int MAX_P2SH_REDEEM_PUSH = 520;
  static final int MAX_CONSENSUS_SCRIPT_SIZE = 10_000;

  public record SpentPrevout(long amount, byte[] scriptPubKey) {}
  public record VerifyInputOptions(
      byte[] scriptPubKey, long amount, List<SpentPrevout> spentPrevouts, SighashCache sighashCache) {
    public VerifyInputOptions(byte[] scriptPubKey, long amount) { this(scriptPubKey, amount, null); }
    public VerifyInputOptions(byte[] scriptPubKey, long amount, List<SpentPrevout> spentPrevouts) {
      this(scriptPubKey, amount, spentPrevouts, null);
    }
  }
  public static void verifyTransactionInput(Transaction transaction, int inputIndex, VerifyInputOptions options) {
    if (inputIndex >= transaction.inputs().size()) throw new ScriptVerifyError("input index out of range");
    byte[] scriptPubKey = options.scriptPubKey();
    Integer witnessVersion = ScriptTemplates.witnessProgramVersion(scriptPubKey);
    if (witnessVersion != null && witnessVersion > 1) throw new ScriptVerifyError("unsupported witness program version " + witnessVersion);
    if (!(ScriptTemplates.isP2pk(scriptPubKey)
        || ScriptTemplates.isP2pkh(scriptPubKey)
        || ScriptTemplates.isP2wpkh(scriptPubKey)
        || ScriptTemplates.isP2wsh(scriptPubKey)
        || ScriptTemplates.isP2sh(scriptPubKey)
        || ScriptTemplates.isP2tr(scriptPubKey)
        || ScriptTemplates.isBareOpN(scriptPubKey)
        || ScriptTemplates.isBareMultisig(scriptPubKey)
        || ScriptTemplates.isBareLegacyScript(scriptPubKey)))
      throw new ScriptVerifyError("unsupported scriptPubKey template");
    TxIn txIn = transaction.inputs().get(inputIndex);
    List<byte[]> witness = transaction.witness().size() > inputIndex ? transaction.witness().get(inputIndex) : List.of();
    if (!verifyScript(txIn.scriptSig(), scriptPubKey, transaction, inputIndex, options.amount(), witness, options.spentPrevouts(), options.sighashCache()))
      throw new ScriptVerifyError("script verification failed for input " + inputIndex);
  }
  static boolean verifyScript(byte[] scriptSig, byte[] scriptPubKey, Transaction tx, int inputIndex, long amount, List<byte[]> witness) {
    return verifyScript(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, null);
  }
  static boolean verifyScript(byte[] scriptSig, byte[] scriptPubKey, Transaction tx, int inputIndex, long amount, List<byte[]> witness, List<SpentPrevout> spentPrevouts) {
    return verifyScript(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, spentPrevouts, null);
  }
  static boolean verifyScript(byte[] scriptSig, byte[] scriptPubKey, Transaction tx, int inputIndex, long amount, List<byte[]> witness, List<SpentPrevout> spentPrevouts, SighashCache sighashCache) {
    if (ScriptTemplates.isP2tr(scriptPubKey)) return Taproot.verifyTaprootSpend(scriptPubKey, scriptSig, witness, tx, inputIndex, spentPrevouts, sighashCache);
    if (ScriptTemplates.isP2wpkh(scriptPubKey)) return verifyP2wpkh(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, sighashCache);
    if (ScriptTemplates.isP2wsh(scriptPubKey)) return verifyP2wsh(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, sighashCache);
    if (ScriptTemplates.isP2sh(scriptPubKey)) return verifyP2sh(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, sighashCache);
    ScriptInterpreter.EvalContext context = new ScriptInterpreter.EvalContext(tx, inputIndex, scriptPubKey, amount, false, sighashCache);
    ScriptInterpreter.EvalOptions options = ScriptInterpreter.EvalOptions.defaults();
    if (ScriptTemplates.isP2pk(scriptPubKey)) {
      if (!witness.isEmpty()) return false;
      try {
        List<byte[]> pushes = ScriptTemplates.parsePushOnlyScriptSig(scriptSig);
        if (pushes.size() != 1 || pushes.getFirst().length == 0) return false;
      } catch (ScriptError error) { return false; }
      ScriptStack stackSig = new ScriptStack();
      try { ScriptInterpreter.evaluateScript(scriptSig, stackSig, context, options); }
      catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
      ScriptStack stack = new ScriptStack(); stack.pushAll(stackSig.snapshot());
      try { ScriptInterpreter.evaluateScript(scriptPubKey, stack, context, options); }
      catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
      return ScriptInterpreter.terminalSuccessStrict(stack);
    }
    boolean bareLegacy =
        ScriptTemplates.isBareOpN(scriptPubKey)
            || ScriptTemplates.isBareMultisig(scriptPubKey)
            || ScriptTemplates.isBareLegacyScript(scriptPubKey);
    if (bareLegacy && !witness.isEmpty()) {
      return false;
    }
    ScriptStack stackSig = new ScriptStack();
    try { ScriptInterpreter.evaluateScript(scriptSig, stackSig, context, options); }
    catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
    ScriptStack stack = new ScriptStack(); stack.pushAll(stackSig.snapshot());
    try { ScriptInterpreter.evaluateScript(scriptPubKey, stack, context, options); }
    catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
    if (ScriptTemplates.isBareOpN(scriptPubKey) && scriptPubKey.length > 1) {
      return ScriptInterpreter.terminalSuccessRelaxed(stack);
    }
    if (ScriptTemplates.isBareLegacyScript(scriptPubKey)) {
      return ScriptInterpreter.terminalSuccessRelaxed(stack);
    }
    // Bare legacy P2PKH: Core block validation does not set SCRIPT_VERIFY_CLEANSTACK; extra
    // scriptSig stack items below a true top are valid (e.g. testnet4 @107951 OP_1 prefix).
    if (ScriptTemplates.isP2pkh(scriptPubKey)) {
      return ScriptInterpreter.terminalSuccessRelaxed(stack);
    }
    return ScriptInterpreter.terminalSuccessStrict(stack);
  }
  private static boolean verifyP2sh(
      byte[] scriptSig,
      byte[] scriptPubKey,
      Transaction tx,
      int inputIndex,
      long amount,
      List<byte[]> witness,
      SighashCache sighashCache) {
    byte[] redeemCandidate;
    try {
      List<byte[]> p2shPushes = ScriptTemplates.parsePushOnlyScriptSig(scriptSig);
      if (p2shPushes.isEmpty() || p2shPushes.getLast().length > MAX_P2SH_REDEEM_PUSH) return false;
      redeemCandidate = p2shPushes.getLast();
    } catch (ScriptError error) {
      return false;
    }
    ScriptInterpreter.EvalContext context = new ScriptInterpreter.EvalContext(tx, inputIndex, scriptPubKey, amount, false, sighashCache);
    ScriptInterpreter.EvalOptions options = ScriptInterpreter.EvalOptions.defaults();
    ScriptStack stackSig = new ScriptStack();
    try { ScriptInterpreter.evaluateScript(scriptSig, stackSig, context, options); }
    catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
    if (stackSig.isEmpty() || !Arrays.equals(stackSig.peek(), redeemCandidate)) return false;
    ScriptStack stack = new ScriptStack(); stack.pushAll(stackSig.snapshot());
    try { ScriptInterpreter.evaluateScript(scriptPubKey, stack, context, options); }
    catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
    if (!ScriptInterpreter.terminalSuccessRelaxed(stack)) return false;
    byte[] expectedHash160 = Arrays.copyOfRange(scriptPubKey, 2, 22);
    if (!Arrays.equals(ScriptHash.hash160(redeemCandidate), expectedHash160)) return false;
    if (ScriptTemplates.isP2wpkh(redeemCandidate)) return verifyP2wpkhWitness(redeemCandidate, tx, inputIndex, amount, witness, sighashCache);
    if (ScriptTemplates.isP2wsh(redeemCandidate)) return verifyP2wshWitness(redeemCandidate, tx, inputIndex, amount, witness, sighashCache);
    ScriptStack inner = new ScriptStack();
    byte[][] sigStack = stackSig.snapshot();
    for (int index = 0; index < sigStack.length - 1; index++) inner.push(sigStack[index]);
    ScriptInterpreter.EvalContext innerContext = new ScriptInterpreter.EvalContext(tx, inputIndex, redeemCandidate, amount, false, sighashCache);
    try { ScriptInterpreter.evaluateScript(redeemCandidate, inner, innerContext, options); }
    catch (UnsupportedScriptRule error) { throw error; } catch (RuntimeException error) { return false; }
    return ScriptInterpreter.terminalSuccessRelaxed(inner);
  }
  private static boolean verifyP2wpkhWitness(
      byte[] redeemScript, Transaction tx, int inputIndex, long amount, List<byte[]> witness, SighashCache sighashCache) {
    if (witness == null || witness.size() != 2) return false;
    byte[] pubkeyHash = Arrays.copyOfRange(redeemScript, 2, redeemScript.length);
    byte[] scriptCode = ScriptTemplates.p2pkhScriptCode(pubkeyHash);
    ScriptStack stack = new ScriptStack();
    ScriptVerifyProfiler.measure(
        "script_stack_setup",
        () -> {
          stack.push(witness.get(0));
          stack.push(witness.get(1));
        });
    ScriptInterpreter.EvalContext context = new ScriptInterpreter.EvalContext(tx, inputIndex, scriptCode, amount, true, sighashCache);
    try {
      ScriptInterpreter.evaluateScript(scriptCode, stack, context, ScriptInterpreter.EvalOptions.defaults());
    } catch (UnsupportedScriptRule error) {
      throw error;
    } catch (RuntimeException error) {
      return false;
    }
    return ScriptInterpreter.terminalSuccessStrict(stack);
  }
  private static boolean verifyP2wshWitness(
      byte[] witnessProgramScript, Transaction tx, int inputIndex, long amount, List<byte[]> witness) {
    return verifyP2wshWitness(witnessProgramScript, tx, inputIndex, amount, witness, null);
  }

  private static boolean verifyP2wshWitness(
      byte[] witnessProgramScript,
      Transaction tx,
      int inputIndex,
      long amount,
      List<byte[]> witness,
      SighashCache sighashCache) {
    byte[] witnessProgram = Arrays.copyOfRange(witnessProgramScript, 2, witnessProgramScript.length);
    return verifyP2wshWitnessStack(witnessProgram, tx, inputIndex, amount, witness, 1, sighashCache);
  }

  private static boolean verifyP2wsh(
      byte[] scriptSig,
      byte[] scriptPubKey,
      Transaction tx,
      int inputIndex,
      long amount,
      List<byte[]> witness,
      SighashCache sighashCache) {
    if (scriptSig != null && scriptSig.length > 0) {
      return false;
    }
    byte[] witnessProgram = Arrays.copyOfRange(scriptPubKey, 2, scriptPubKey.length);
    return verifyP2wshWitnessStack(witnessProgram, tx, inputIndex, amount, witness, 1, sighashCache);
  }

  private static boolean verifyP2wshWitnessStack(
      byte[] witnessProgram, Transaction tx, int inputIndex, long amount, List<byte[]> witness, int minWitnessItems, SighashCache sighashCache) {
    if (witness == null || witness.size() < minWitnessItems) return false;
    byte[] witnessScript = witness.getLast();
    if (witnessScript == null || witnessScript.length == 0 || witnessScript.length > MAX_CONSENSUS_SCRIPT_SIZE) return false;
    if (!Arrays.equals(ScriptHash.sha256(witnessScript), witnessProgram)) return false;
    ScriptStack stack = new ScriptStack();
    ScriptVerifyProfiler.measure(
        "script_stack_setup",
        () -> {
          for (int index = 0; index < witness.size() - 1; index++) stack.push(witness.get(index));
        });
    ScriptInterpreter.EvalContext context = new ScriptInterpreter.EvalContext(tx, inputIndex, witnessScript, amount, true, sighashCache);
    try {
      ScriptInterpreter.evaluateScript(witnessScript, stack, context, ScriptInterpreter.EvalOptions.defaults());
    } catch (UnsupportedScriptRule error) {
      throw error;
    } catch (RuntimeException error) {
      return false;
    }
    return ScriptInterpreter.terminalSuccessStrict(stack);
  }

  private static boolean verifyP2wpkh(
      byte[] scriptSig,
      byte[] scriptPubKey,
      Transaction tx,
      int inputIndex,
      long amount,
      List<byte[]> witness) {
    return verifyP2wpkh(scriptSig, scriptPubKey, tx, inputIndex, amount, witness, null);
  }

  private static boolean verifyP2wpkh(
      byte[] scriptSig,
      byte[] scriptPubKey,
      Transaction tx,
      int inputIndex,
      long amount,
      List<byte[]> witness,
      SighashCache sighashCache) {
    if (scriptSig != null && scriptSig.length > 0) {
      return false;
    }
    if (witness == null || witness.size() != 2) {
      return false;
    }
    byte[] pubkeyHash = Arrays.copyOfRange(scriptPubKey, 2, scriptPubKey.length);
    byte[] scriptCode = ScriptTemplates.p2pkhScriptCode(pubkeyHash);
    ScriptStack stack = new ScriptStack();
    ScriptVerifyProfiler.measure(
        "script_stack_setup",
        () -> {
          stack.push(witness.get(0));
          stack.push(witness.get(1));
        });
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, inputIndex, scriptCode, amount, true, sighashCache);
    try {
      ScriptInterpreter.evaluateScript(
          scriptCode, stack, context, ScriptInterpreter.EvalOptions.defaults());
    } catch (UnsupportedScriptRule error) {
      throw error;
    } catch (RuntimeException error) {
      return false;
    }
    return ScriptInterpreter.terminalSuccessStrict(stack);
  }
  public static String describeScriptPubKey(byte[] scriptPubKey) {
    if (ScriptTemplates.isP2pkh(scriptPubKey)) return "P2PKH";
    if (ScriptTemplates.isP2pk(scriptPubKey)) return "P2PK";
    if (ScriptTemplates.isP2tr(scriptPubKey)) return "P2TR";
    if (ScriptTemplates.isP2wpkh(scriptPubKey)) return "P2WPKH";
    if (ScriptTemplates.isP2wsh(scriptPubKey)) return "P2WSH";
    if (ScriptTemplates.isP2sh(scriptPubKey)) return "P2SH";
    if (ScriptTemplates.isBareOpN(scriptPubKey)) return "bare_op_n";
    if (ScriptTemplates.isBareMultisig(scriptPubKey)) return "bare_multisig";
    if (ScriptTemplates.isBareLegacyScript(scriptPubKey)) return "bare_legacy";
    return "unknown:" + Hex.encode(scriptPubKey);
  }
}
