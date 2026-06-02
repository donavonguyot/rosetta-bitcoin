package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

class P2pkh61174Hash160Test {
  @Test
  void pubkeyHash160MatchesScriptPubKey() {
    byte[] scriptSig = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_scriptsig.hex");
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2pkh_61174_prev_spk.hex");
    int sigLen = scriptSig[0] & 0xff;
    byte[] pubkey = java.util.Arrays.copyOfRange(scriptSig, sigLen + 2, scriptSig.length);
    byte[] hash160 = ScriptHash.hash160(pubkey);
    byte[] embedded = java.util.Arrays.copyOfRange(prevSpk, 3, 23);
    assertArrayEquals(embedded, hash160);
    assertTrue(ScriptTemplates.isP2pkh(prevSpk));
  }
}
