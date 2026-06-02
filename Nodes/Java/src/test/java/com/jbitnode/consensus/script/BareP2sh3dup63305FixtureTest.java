package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 63305 P2SH OP_3DUP redeem spend (BLOCKER_LEDGER). */
class BareP2sh3dup63305FixtureTest {

  static final String TXID =
      "5f2ef82d267e50f4f15c4dc1c04c3b2b1ca74be0fec19697f44cb438ff85caeb";
  static final String PREV_SPK =
      "a914da5a92e670a66538be1c550af352646000b2367d87";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_3dup_63305.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.version());
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.witness().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2sh_3dup_63305_prev_spk.hex"));
    byte[] redeemScript =
        FixtureLoader.readHex("/fixtures/tx_p2sh_3dup_63305_redeem_script.hex");
    assertEquals(OpCodes.OP_3DUP, redeemScript[0] & 0xff);
    assertEquals(OpCodes.OP_1, redeemScript[redeemScript.length - 1] & 0xff);
  }
}
