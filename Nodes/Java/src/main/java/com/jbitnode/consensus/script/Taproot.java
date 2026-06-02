package com.jbitnode.consensus.script;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.Transaction;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** BIP341 P2TR key-path and script-path spend verification. */
public final class Taproot {

  public static final int WITNESS_V1_TAPROOT_XONLY_PK_LEN = 32;
  private static final int ANNEX_TAG = 0x50;

  private Taproot() {}

  /**
   * Verify a P2TR spend (key-path or script-path). Empty scriptSig required.
   *
   * <p>Annex spends are rejected until implemented.
   */
  public static boolean verifyTaprootSpend(
      byte[] scriptPubKey,
      byte[] scriptSig,
      List<byte[]> witness,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts) {
    return verifyTaprootSpend(scriptPubKey, scriptSig, witness, tx, inputIndex, spentPrevouts, null);
  }

  public static boolean verifyTaprootSpend(
      byte[] scriptPubKey,
      byte[] scriptSig,
      List<byte[]> witness,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      SighashCache sighashCache) {
    return ScriptVerifyProfiler.measure(
        "script_taproot_dispatch",
        () -> {
          if (!ScriptTemplates.isP2tr(scriptPubKey)) {
            return false;
          }
          if (scriptSig != null && scriptSig.length > 0) {
            return false;
          }
          if (spentPrevouts == null) {
            return false;
          }

          List<byte[]> witnessItems = new ArrayList<>(witness != null ? witness : List.of());
          byte[] serializedWitnessForWeight =
              ScriptVerifyProfiler.measure(
                  "script_taproot_witness_serialize",
                  () -> TaprootHash.serializedWitnessStackBytes(witnessItems));

          byte[] annex = null;
          if (witnessItems.size() >= 2
              && witnessItems.getLast().length > 0
              && (witnessItems.getLast()[0] & 0xff) == ANNEX_TAG) {
            return false;
          }

          if (witnessItems.size() >= 2) {
            return ScriptVerifyProfiler.measure(
                "script_taproot_script_path",
                () ->
                    verifyScriptPathSpend(
                        scriptPubKey,
                        witnessItems,
                        annex,
                        tx,
                        inputIndex,
                        spentPrevouts,
                        serializedWitnessForWeight,
                        sighashCache));
          }
          return ScriptVerifyProfiler.measure(
              "script_taproot_key_path",
              () ->
                  verifyKeyPathSpendInternal(
                      scriptPubKey, witnessItems, annex, tx, inputIndex, spentPrevouts, sighashCache));
        });
  }

  /**
   * Verify a P2TR key-path spend: empty scriptSig, single 64-byte Schnorr signature witness item.
   */
  public static boolean verifyKeyPathSpend(
      byte[] scriptPubKey,
      byte[] scriptSig,
      List<byte[]> witness,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts) {
    return verifyTaprootSpend(
        scriptPubKey, scriptSig, witness, tx, inputIndex, spentPrevouts);
  }

  private static boolean verifyKeyPathSpendInternal(
      byte[] scriptPubKey,
      List<byte[]> witnessItems,
      byte[] annex,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      SighashCache sighashCache) {
    if (witnessItems.size() != 1) {
      return false;
    }

    byte[] outputKeyX = Arrays.copyOfRange(scriptPubKey, 2, scriptPubKey.length);
    byte[] sigBlob = witnessItems.getFirst();
    if (sigBlob.length != 64 && sigBlob.length != 65) {
      return false;
    }

    int hashType = TaprootSighash.TAPROOT_SIGHASH_DEFAULT;
    byte[] sig64 = sigBlob;
    if (sigBlob.length == 65) {
      hashType = sigBlob[64] & 0xff;
      if (hashType == TaprootSighash.TAPROOT_SIGHASH_DEFAULT) {
        return false;
      }
      sig64 = Arrays.copyOfRange(sigBlob, 0, 64);
    }

    byte[] message;
    try {
      message =
          TaprootSighash.taprootSignatureHash(
              tx,
              inputIndex,
              spentPrevouts,
              TaprootSighash.TaprootSighashOptions.keyPath(hashType),
              sighashCache != null ? sighashCache.taprootCache() : null);
    } catch (IllegalArgumentException error) {
      return false;
    }

    return Secp256k1.verifySchnorrSignature(
        outputKeyX,
        message,
        sig64,
        sighashCache != null ? sighashCache.secp256k1Cache() : null);
  }

  private static boolean verifyScriptPathSpend(
      byte[] scriptPubKey,
      List<byte[]> witnessItemsWithoutAnnex,
      byte[] annex,
      Transaction tx,
      int inputIndex,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      byte[] serializedWitnessForWeight,
      SighashCache sighashCache) {
    if (spentPrevouts.size() != tx.inputs().size()) {
      return false;
    }
    if (witnessItemsWithoutAnnex.size() < 2) {
      return false;
    }

    byte[] scriptBytes = witnessItemsWithoutAnnex.get(witnessItemsWithoutAnnex.size() - 2);
    byte[] control = witnessItemsWithoutAnnex.getLast();
    List<byte[]> stackItems =
        witnessItemsWithoutAnnex.subList(0, witnessItemsWithoutAnnex.size() - 2);

    if (scriptBytes.length == 0) {
      return false;
    }
    int controlLength = control.length;
    if (controlLength < 33
        || controlLength > 33 + 128 * 32
        || (controlLength - 33) % 32 != 0) {
      return false;
    }

    int leafMasked = control[0] & 0xfe;
    if (leafMasked == ANNEX_TAG) {
      return false;
    }

    byte[] internalX = Arrays.copyOfRange(control, 1, 33);
    List<byte[]> merkleBranch = new ArrayList<>();
    ScriptVerifyProfiler.measure(
        "script_taproot_control_parse",
        () -> {
          for (int index = 33; index < controlLength; index += 32) {
            merkleBranch.add(Arrays.copyOfRange(control, index, index + 32));
          }
        });

    byte[] leafDigest;
    byte[] outputX;
    int parityOut;
    try {
      leafDigest =
          ScriptVerifyProfiler.measure(
              "script_taproot_leaf_hash", () -> TaprootHash.tapleafHash(leafMasked, scriptBytes));
      byte[] merkleRoot =
          ScriptVerifyProfiler.measure(
              "script_taproot_merkle_root",
              () -> TaprootHash.taprootMerkleRootFromBranch(merkleBranch, leafDigest));
      Secp256k1.TaprootTweakResult tweak =
          ScriptVerifyProfiler.measure(
              "script_taproot_tweak_verify",
              () ->
                  Secp256k1.taprootTweakPubkeyXonly(
                      internalX,
                      merkleRoot,
                      sighashCache != null ? sighashCache.secp256k1Cache() : null));
      parityOut = tweak.parity();
      outputX = tweak.outputXonly();
    } catch (RuntimeException error) {
      return false;
    }

    if (!rangeEquals(scriptPubKey, 2, outputX) || control[0] != (byte) (leafMasked | parityOut)) {
      return false;
    }

    if (leafMasked != TaprootHash.TAPROOT_LEAF_VERSION_TAPSCRIPT) {
      return true;
    }

    if (Tapscript.prescanOpSuccess(scriptBytes)) {
      return true;
    }

    if (stackItems.size() > Tapscript.MAX_TAPSCRIPT_STACK_ELEMENTS) {
      return false;
    }
    for (byte[] element : stackItems) {
      if (element.length > Tapscript.MAX_SCRIPT_ELEMENT_SIZE_CONSENSUS) {
        return false;
      }
    }

    int[] budget = {Tapscript.VALIDATION_WEIGHT_OFFSET + serializedWitnessForWeight.length};
    ScriptStack execStack = new ScriptStack();
    ScriptVerifyProfiler.measure(
        "script_taproot_stack_setup",
        () -> {
          for (byte[] stackItem : stackItems) {
            execStack.push(stackItem);
          }
        });
    try {
      Tapscript.evaluate(
          scriptBytes,
          execStack,
          tx,
          inputIndex,
          leafDigest,
          spentPrevouts,
          annex,
          budget,
          sighashCache);
    } catch (ScriptError error) {
      return false;
    }

    return ScriptInterpreter.terminalSuccessStrict(execStack);
  }

  public static byte[] taprootOutputKeyXonly(byte[] internalXonly, byte[] merkleRoot) {
    return Secp256k1.taprootOutputKeyXonly(internalXonly, merkleRoot);
  }

  public static java.math.BigInteger taprootTweakScalar(byte[] internalXonly, byte[] merkleRoot) {
    return Secp256k1.taprootTweakScalar(internalXonly, merkleRoot);
  }

  private static boolean rangeEquals(byte[] source, int sourceOffset, byte[] expected) {
    if (source.length - sourceOffset != expected.length) {
      return false;
    }
    for (int index = 0; index < expected.length; index++) {
      if (source[sourceOffset + index] != expected[index]) {
        return false;
      }
    }
    return true;
  }
}
