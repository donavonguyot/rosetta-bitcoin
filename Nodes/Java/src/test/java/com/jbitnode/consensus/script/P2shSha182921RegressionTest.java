package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/** Regression for testnet4 block 82921 P2SH SHA1 collision redeem script spend. */
class P2shSha182921RegressionTest {

  static final long PREVOUT_AMOUNT = 8_256L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] redeemScript = FixtureLoader.readHex("/fixtures/tx_p2sh_sha1_82921_redeem_script.hex");
    assertEquals(OpCodes.OP_2DUP, redeemScript[0] & 0xff);
    assertEquals(OpCodes.OP_NOT, redeemScript[2] & 0xff);
    assertEquals(OpCodes.OP_SHA1, redeemScript[4] & 0xff);
  }

  @Test
  void acceptsRealTestnet4Block82921P2shSha1Input0() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_sha1_82921.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] prevSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_sha1_82921_prev_spk.hex");

    assertDoesNotThrow(
        () ->
            ScriptVerify.verifyTransactionInput(
                tx, 0, new ScriptVerify.VerifyInputOptions(prevSpk, PREVOUT_AMOUNT)));
  }
}
