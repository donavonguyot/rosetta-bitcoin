package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 62754 P2WSH OP_ROT witness spend (BLOCKER_LEDGER). */
class BareP2wshRot62754FixtureTest {

  static final String TXID =
      "f4ecb76ed2bb8e4a7540a060bb97dc1d417dc3c8a54200aa7c589b74a931d82a";
  static final String PREV_SPK =
      "002055cec8793c26a9cbcf8cdfb1c715ce567fe451a47deb114df9efa31218d5b2ac";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_rot_62754.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.version());
    assertEquals(1, tx.inputs().size());
    assertEquals(0x3cL, tx.inputs().getFirst().sequence());
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2wsh_rot_62754_prev_spk.hex"));
    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_rot_62754_witness_script.hex");
    assertEquals(OpCodes.OP_SIZE, witnessScript[0] & 0xff);
    assertEquals(OpCodes.OP_ROT, witnessScript[104] & 0xff);
    assertEquals(OpCodes.OP_CHECKSIG, witnessScript[106] & 0xff);
  }
}
