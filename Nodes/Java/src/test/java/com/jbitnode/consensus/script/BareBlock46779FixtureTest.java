package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 46779 P2WSH witness-script spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5},
 * input 0 spends native P2WSH {@code 0020359eaf2f…}. Witness stack: DER signature,
 * witnessScript ending {@code OP_SIZE OP_LESSTHAN OP_VERIFY OP_CODESEPARATOR OP_CHECKSIG}.
 * Empty scriptSig.
 *
 * <p>Harvested via Core RPC {@code 127.0.0.1:48332}. Main agent diagnoses missing legacy
 * opcodes; this test only anchors fixture fields.
 */
class BareBlock46779FixtureTest {

  static final String TXID =
      "fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5";
  static final String PREV_SPK =
      "0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(2, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(2, tx.witness().size());
    assertEquals(2, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK),
        FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_prev_spk.hex"));
    assertEquals(
        0, FixtureLoader.readBytes("/fixtures/tx_p2wsh_size_lessthan_46779_scriptsig.hex").length);
    assertEquals(
        71, FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_witness_0.hex").length);
    assertEquals(
        41, FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_witness_script.hex").length);

    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_witness_script.hex");
    assertEquals(0x82, witnessScript[0] & 0xFF);
    assertEquals(0x50, witnessScript[2] & 0xFF);
    assertEquals(0x9F, witnessScript[3] & 0xFF);
    assertEquals(0x69, witnessScript[4] & 0xFF);
    assertEquals(0xAB, witnessScript[5] & 0xFF);
    assertEquals(0xAC, witnessScript[witnessScript.length - 1] & 0xFF);
    assertArrayEquals(
        witnessScript,
        FixtureLoader.readHex("/fixtures/tx_p2wsh_size_lessthan_46779_witness_1.hex"));
  }
}
