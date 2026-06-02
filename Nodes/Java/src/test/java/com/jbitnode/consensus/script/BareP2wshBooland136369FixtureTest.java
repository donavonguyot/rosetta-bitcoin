package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 136369 P2WSH OP_BOOLAND witness spend (BLOCKER_LEDGER). */
class BareP2wshBooland136369FixtureTest {

  static final String PREV_SPK =
      "002015d8d785605bb57624a0fb5ce61211f3279edb9b6a9a5750f602bcbe5451537d";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_booland_136369.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.version());
    assertEquals(1, tx.inputs().size());
    assertEquals(0xfffffffdL, tx.inputs().getFirst().sequence());
    assertEquals(1, tx.witness().size());
    assertEquals(3, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK),
        FixtureLoader.readHex("/fixtures/tx_p2wsh_booland_136369_prev_spk.hex"));
    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_booland_136369_witness_script.hex");
    assertEquals(OpCodes.OP_SIZE, witnessScript[0] & 0xff);
    assertEquals(OpCodes.OP_RIPEMD160, witnessScript[4] & 0xff);
    assertEquals(OpCodes.OP_BOOLAND, witnessScript[witnessScript.length - 1] & 0xff);
  }
}
