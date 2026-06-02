package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 32712 P2TR tapscript {@code OP_NUMEQUAL} 2-of-3
 * (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94},
 * input 0 spends P2TR {@code 51203a6c3681…}. Script-path witness: two Schnorr
 * signatures, tapscript ending {@code OP_2 OP_NUMEQUAL}, 33-byte control block.
 *
 * <p>Python scout: {@code
 * test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted}.
 */
class BareFixture32712Test {

  static final String TXID =
      "6b586a4f831e267749a3c2e50b866fe5badb582d3d388ea636669cbdc13acd94";
  static final long P2TR_AMOUNT = 50_000L;

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(1, tx.witness().size());
    assertEquals(5, tx.witness().getFirst().size());

    byte[] p2trSpk = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_prev_spk.hex");
    assertEquals(34, p2trSpk.length);
    assertEquals(0x51, p2trSpk[0] & 0xFF);
    assertEquals(0x20, p2trSpk[1] & 0xFF);

    assertEquals(0, FixtureLoader.readBytes("/fixtures/tx_p2tr_tapscript_numequal_32712_witness_0.hex").length);
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_witness_1.hex").length);
    assertEquals(64, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_witness_2.hex").length);

    byte[] tapscript = FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_tapscript.hex");
    assertEquals(104, tapscript.length);
    assertEquals(0x20, tapscript[0] & 0xFF);
    assertEquals(0x9c, tapscript[tapscript.length - 1] & 0xFF);
    assertArrayEquals(
        tapscript, FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_witness_3.hex"));

    byte[] controlBlock =
        FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_control_block.hex");
    assertEquals(33, controlBlock.length);
    assertEquals(0xc0, controlBlock[0] & 0xFF);
    assertArrayEquals(
        controlBlock,
        FixtureLoader.readHex("/fixtures/tx_p2tr_tapscript_numequal_32712_witness_4.hex"));
  }
}
