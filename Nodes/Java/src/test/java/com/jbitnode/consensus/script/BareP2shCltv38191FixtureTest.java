package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchors for block 38191 P2SH CLTV harvest (read-only). */
class BareP2shCltv38191FixtureTest {

  @Test
  void redeemScriptMatchesCoreDecode() {
    byte[] redeem = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191_redeem_script.hex");
    assertEquals(40, redeem.length);
    assertArrayEquals(
        Hex.decode(
            "023075b175210373cec267e77fc3c13e90d74b8975926352e948033e8e51b218d6ba144b0ebbeeac"),
        redeem);
  }

  @Test
  void prevoutScriptPubKeyMatchesLedger() {
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_cltv_38191_prev_spk.hex");
    assertArrayEquals(
        Hex.decode("a914bbe352f1c5366dd92bcae64f4de33e6b56df7e3d87"), prevSpk);
  }
}
