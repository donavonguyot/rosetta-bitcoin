package com.jbitnode.scripts;

import com.jbitnode.consensus.script.OpCodes;
import com.jbitnode.consensus.script.ScriptTemplates;

/** Classifies scriptPubKey locking templates for offline survey. */
public final class ScriptTemplateClassifier {

  public static final String P2PK = "p2pk";
  public static final String P2PKH = "p2pkh";
  public static final String P2WPKH = "p2wpkh";
  public static final String P2TR = "p2tr";
  public static final String P2WSH = "p2wsh";
  public static final String P2SH = "p2sh";
  public static final String UNKNOWN = "unknown";

  private ScriptTemplateClassifier() {}

  /** Returns a lowercase template label (aligned with Python/TypeScript survey tools). */
  public static String classify(byte[] scriptPubKey) {
    if (ScriptTemplates.isP2tr(scriptPubKey)) {
      return P2TR;
    }
    if (ScriptTemplates.isP2wpkh(scriptPubKey)) {
      return P2WPKH;
    }
    if (ScriptTemplates.isP2wsh(scriptPubKey)) {
      return P2WSH;
    }
    Integer witnessVersion = ScriptTemplates.witnessProgramVersion(scriptPubKey);
    if (witnessVersion != null && witnessVersion > 1) {
      return "witness_v" + witnessVersion;
    }
    if (ScriptTemplates.isP2sh(scriptPubKey)) {
      return P2SH;
    }
    if (ScriptTemplates.isP2pkh(scriptPubKey)) {
      return P2PKH;
    }
    if (ScriptTemplates.isP2pk(scriptPubKey)) {
      return P2PK;
    }
    if (ScriptTemplates.isBareOpN(scriptPubKey)) {
      return "bare_op_n";
    }
    if (ScriptTemplates.isBareMultisig(scriptPubKey)) {
      return "bare_multisig";
    }
    if (scriptPubKey.length == 0) {
      return "empty";
    }
    if ((scriptPubKey[0] & 0xff) == 0x6a) {
      return "op_return";
    }
    return String.format(
        "other(0x%02x,len=%d)", scriptPubKey[0] & 0xff, scriptPubKey.length);
  }

  /** Maps a classify label to the survey spend category (P2PK … UNKNOWN). */
  public static String spendCategory(String label) {
    return switch (label) {
      case P2PK, P2PKH, P2WPKH, P2TR, P2WSH, P2SH -> label;
      default -> UNKNOWN;
    };
  }

  public static boolean isKnownSpendCategory(String category) {
    return switch (category) {
      case P2PK, P2PKH, P2WPKH, P2TR, P2WSH, P2SH -> true;
      default -> false;
    };
  }
}
