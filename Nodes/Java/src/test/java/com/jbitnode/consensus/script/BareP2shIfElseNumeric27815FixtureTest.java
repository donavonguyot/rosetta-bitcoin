package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.testutil.FixtureLoader;
import org.junit.jupiter.api.Test;

/**
 * Fixture anchor for testnet4 block 27815 P2SH OP_IF numeric branch spend (BLOCKER_LEDGER).
 *
 * <p>Tx {@code 2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7}, input 0
 * spends P2SH {@code a9149bd8…} with branch selector {@code OP_1} (IF numeric path: operand
 * {@code 2001} vs constant {@code 2024}, threshold {@code 18}, {@code OP_SWAP OP_SUB
 * OP_GREATERTHAN OP_VERIFY}).
 */
class BareP2shIfElseNumeric27815FixtureTest {

  static final String TXID =
      "2a691884927c92649b0c8759f929b931ba21d75bb21bc21f4a3b5868be0bc4d7";
  static final long P2SH_AMOUNT = 740_492L;
  static final String IF_BRANCH_HEX = "02e8077c940112a069";

  @Test
  void fixtureDocumentsExpectedFields() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815.hex");
    TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, 0);
    assertTrue(parsed.nextOffset() == payload.length);

    Transaction tx = parsed.transaction();
    assertEquals(1, tx.inputs().size());
    assertEquals(1, tx.outputs().size());
    assertEquals(0, tx.witness().size());

    byte[] p2shSpk = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_prev_spk.hex");
    assertEquals(23, p2shSpk.length);
    assertEquals(0xA9, p2shSpk[0] & 0xFF);
    assertEquals(0x14, p2shSpk[1] & 0xFF);

    assertEquals(72, FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_scriptsig_sig.hex").length);
    byte[] operand = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_scriptsig_operand.hex");
    assertEquals(2, operand.length);
    assertEquals(2001, (operand[0] & 0xFF) | ((operand[1] & 0xFF) << 8));
    assertEquals(0x51, FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_scriptsig_branch.hex")[0] & 0xFF);

    byte[] redeem = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_redeem_script.hex");
    assertEquals(114, redeem.length);
    assertEquals(0x63, redeem[0] & 0xFF);
    assertEquals(0x67, redeem[10] & 0xFF);
    assertEquals(0xA8, redeem[11] & 0xFF);
    assertEquals(0x68, redeem[46] & 0xFF);
    assertEquals(0xAC, redeem[redeem.length - 1] & 0xFF);

    byte[] ifBranch = FixtureLoader.readHex("/fixtures/tx_p2sh_ifelse_numeric_27815_redeem_if_branch.hex");
    assertEquals(IF_BRANCH_HEX, FixtureLoader.readText("/fixtures/tx_p2sh_ifelse_numeric_27815_redeem_if_branch.hex").trim());
    assertEquals(9, ifBranch.length);
    assertEquals(0x7C, ifBranch[3] & 0xFF);
    assertEquals(0x94, ifBranch[4] & 0xFF);
    assertEquals(0xA0, ifBranch[7] & 0xFF);
    assertEquals(0x69, ifBranch[8] & 0xFF);
  }
}
