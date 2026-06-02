package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 54297 P2WSH IFDUP/CSV spend (BLOCKER_LEDGER). */
class BareP2wshIfdupCsv54297FixtureTest {

  static final String TXID =
      "00b7207d21c697a183da730622117a4091ccaea238976ef0341267579ac29b12";
  static final String PREV_SPK =
      "00202c832ce8af0a8020f3d06b18a5e2de71663c535870d99fd69a5c184d6245e441";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_ifdup_csv_54297.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.version());
    assertEquals(1, tx.inputs().size());
    assertEquals(2L, tx.inputs().getFirst().sequence());
    assertEquals(1, tx.witness().size());
    assertEquals(6, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2wsh_ifdup_csv_54297_prev_spk.hex"));
    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_ifdup_csv_54297_witness_script.hex");
    assertEquals((byte) 0x52, witnessScript[0]);
    assertEquals((byte) OpCodes.OP_CHECKMULTISIG, witnessScript[70]);
    assertEquals((byte) OpCodes.OP_IFDUP, witnessScript[71]);
  }
}
