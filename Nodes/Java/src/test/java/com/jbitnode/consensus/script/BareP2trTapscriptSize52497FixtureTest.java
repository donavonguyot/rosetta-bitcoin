package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

/** Fixture anchor for testnet4 block 52497 P2TR tapscript {@code OP_SIZE} hashlock spend (BLOCKER_LEDGER). */
class BareP2trTapscriptSize52497FixtureTest {

  static final String TXID =
      "c62c3c4c40feb1850f17ccbd33693c26d3ce83910c5a3fe5c058f30ecec8c6e7";
  static final String PREV_SPK =
      "512031b46e4751f440b63193188b859158ab5560beac41d33a3251cbfa88a1192986";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(0, tx.inputs().getFirst().scriptSig().length);
    assertEquals(1, tx.witness().size());
    assertEquals(6, tx.witness().getFirst().size());

    assertArrayEquals(
        Hex.decode(PREV_SPK), FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_prev_spk.hex"));
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_witness_0.hex").length);
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_witness_1.hex").length);
    assertEquals(16, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_witness_3.hex").length);
    assertEquals(154, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_tapscript.hex").length);
    assertEquals(65, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_control_block.hex").length);

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_tapscript.hex");
    assertEquals((byte) OpCodes.OP_DUP, tapscript[0]);
    assertEquals((byte) OpCodes.OP_SHA256, tapscript[1]);
    assertTrue(containsOpcode(tapscript, OpCodes.OP_SIZE));
    assertEquals((byte) OpCodes.OP_CHECKSIG, tapscript[tapscript.length - 1]);

    byte[] control = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_size_52497_control_block.hex");
    assertEquals(0xC0, control[0] & 0xFE);
  }

  private static boolean containsOpcode(byte[] script, int opcode) {
    for (byte b : script) {
      if ((b & 0xFF) == opcode) {
        return true;
      }
    }
    return false;
  }
}
