package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 63603 P2SH OP_2DUP redeem spend (BLOCKER_LEDGER). */
class BareP2sh2dup63603FixtureTest {

  static final String TXID =
      "a21adb17edebeee255310e9b37c44a667e7a510bc8181efbf734a86bcac94f74";
  static final String PREV_SPK =
      "a9143b2169f7881b3c7d812ce17220f8080e817aac7e87";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.version());
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.witness().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603_prev_spk.hex"));
    byte[] redeemScript =
        FixtureLoader.readHex("/fixtures/tx_p2sh_2dup_63603_redeem_script.hex");
    assertEquals(OpCodes.OP_2DUP, redeemScript[0] & 0xff);
    assertEquals(OpCodes.OP_EQUAL, redeemScript[redeemScript.length - 1] & 0xff);
  }
}
