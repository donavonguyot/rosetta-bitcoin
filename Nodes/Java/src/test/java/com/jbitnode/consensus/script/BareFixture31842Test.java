package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 31842 P2WSH len-1 witness edge (BLOCKER_LEDGER).
 *
 * <p>Tx {@code b6dc55194be800938ea64ceaad98c299bbfe8590b2472779218808746f4a2659},
 * input 0 spends P2WSH {@code 00204ae81572…}. Witness stack is {@code [witnessScript]}
 * only (length 1); witness script is single byte {@code OP_1 (0x51)}.
 *
 * <p>Python scout: {@code test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted}.
 */
class BareFixture31842Test {

  static final String TXID =
      "b6dc55194be800938ea64ceaad98c299bbfe8590b2472779218808746f4a2659";
  static final long P2WSH_AMOUNT = 69_179L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2wsh_op1_only_31842.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(6, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(6, tx.witness().size());
    assertEquals(1, tx.witness().getFirst().size());
    for (int i = 1; i < 6; i++) {
      List<byte[]> stack = tx.witness().get(i);
      assertEquals(1, stack.size());
      assertEquals(64, stack.getFirst().length);
    }

    byte[] p2wshSpk = FixtureLoader.readHex("/fixtures/tx_p2wsh_op1_only_31842_prev_spk.hex");
    assertEquals(34, p2wshSpk.length);
    assertEquals(0x00, p2wshSpk[0] & 0xFF);
    assertEquals(0x20, p2wshSpk[1] & 0xFF);

    byte[] witnessScript =
        FixtureLoader.readHex("/fixtures/tx_p2wsh_op1_only_31842_witness_script.hex");
    assertEquals(1, witnessScript.length);
    assertEquals(0x51, witnessScript[0] & 0xFF);
    assertArrayEquals(
        witnessScript, FixtureLoader.readHex("/fixtures/tx_p2wsh_op1_only_31842_witness_0.hex"));
  }
}
