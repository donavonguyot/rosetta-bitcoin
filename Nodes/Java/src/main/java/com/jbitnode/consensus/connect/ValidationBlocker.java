package com.jbitnode.consensus.connect;

import com.jbitnode.util.Hex;

/** Structured consensus blocker for follower handoff (M10). */
public final class ValidationBlocker extends ConnectBlockException {

  private final int height;
  private final String blockHashHex;
  private final String txidHex;
  private final int inputIndex;
  private final String spentScriptPubKeyHex;
  private final String missingRule;

  public ValidationBlocker(
      int height,
      String blockHashHex,
      String txidHex,
      int inputIndex,
      String spentScriptPubKeyHex,
      String failure,
      String missingRule) {
    super(failure);
    this.height = height;
    this.blockHashHex = blockHashHex;
    this.txidHex = txidHex;
    this.inputIndex = inputIndex;
    this.spentScriptPubKeyHex = spentScriptPubKeyHex;
    this.missingRule = missingRule;
  }

  public int height() {
    return height;
  }

  public String blockHashHex() {
    return blockHashHex;
  }

  public String txidHex() {
    return txidHex;
  }

  public int inputIndex() {
    return inputIndex;
  }

  public String spentScriptPubKeyHex() {
    return spentScriptPubKeyHex;
  }

  public String missingRule() {
    return missingRule;
  }

  public String ledgerEntry() {
    return """
        height: %d
        block_hash: %s
        txid: %s
        input_index: %d
        spent_script_pubkey: %s
        failure: %s
        missing_rule: %s
        python_reference: pybitnode/consensus/script/interpreter.py, verify.py
        java_test: com.jbitnode.consensus.script.ScriptVerifyTest
        java_fix: pending
        follower_notes: M9/M10 stop-at-blocker
        """
        .formatted(
            height,
            blockHashHex,
            txidHex,
            inputIndex,
            spentScriptPubKeyHex,
            getMessage(),
            missingRule);
  }

  public static ValidationBlocker fromUnsupportedTemplate(
      int height,
      String blockHashHex,
      String txidHex,
      int inputIndex,
      byte[] scriptPubKey,
      String templateName) {
    String scriptHex = Hex.encode(scriptPubKey);
    return new ValidationBlocker(
        height,
        blockHashHex,
        txidHex,
        inputIndex,
        scriptHex,
        "unsupported scriptPubKey template: " + templateName,
        templateName);
  }
}
