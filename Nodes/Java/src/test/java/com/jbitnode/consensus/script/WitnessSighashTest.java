package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.testutil.ScriptTestHelpers;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.List;
import org.junit.jupiter.api.Test;

class WitnessSighashTest {

  @Test
  void bip143SighashAllMatchesSyntheticP2wpkhSpend() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] prevTxid = Hex.decode("cc".repeat(32));
    ScriptTestHelpers.SignedSpend spend =
        ScriptTestHelpers.makeSignedP2wpkhSpend(privateKey, prevTxid, 0, 50_000, pubkey, 49_000);
    byte[] scriptCode =
        ScriptTemplates.p2pkhScriptCode(ScriptHash.hash160(pubkey));
    byte[] digest = WitnessSighash.bip143Sighash(spend.transaction(), 0, scriptCode, 50_000, 1);
    assertEquals(32, digest.length);
  }

  @Test
  void rejectsOutOfRangeInputIndex() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        IllegalArgumentException.class,
        () -> WitnessSighash.bip143Sighash(tx, 1, new byte[] {0x51}, 1, 1));
  }

  @Test
  void coversAnyoneCanPayAndSingleOutputBranches() {
    BigInteger privateKey = BigInteger.valueOf(2);
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] scriptCode =
        ScriptTemplates.p2pkhScriptCode(ScriptHash.hash160(pubkey));
    byte[] prevA = Hex.decode("aa".repeat(32));
    byte[] prevB = Hex.decode("bb".repeat(32));
    Transaction tx =
        new Transaction(
            2,
            List.of(
                new TxIn(new OutPoint(prevA, 0), new byte[0], 1),
                new TxIn(new OutPoint(prevB, 1), new byte[0], 2)),
            List.of(new TxOut(10, new byte[] {0x51}), new TxOut(20, new byte[] {0x52})),
            0,
            List.of(List.of(), List.of()));

    byte[] anyoneCanPay =
        WitnessSighash.bip143Sighash(tx, 0, scriptCode, 50_000, 0x81 | 1);
    byte[] none =
        WitnessSighash.bip143Sighash(tx, 0, scriptCode, 50_000, 2);
    byte[] single =
        WitnessSighash.bip143Sighash(tx, 1, scriptCode, 60_000, 3);
    assertEquals(32, anyoneCanPay.length);
    assertEquals(32, none.length);
    assertEquals(32, single.length);
  }

  @Test
  void cachedBip143SighashMatchesUncachedBranches() {
    byte[] scriptCode = ScriptTemplates.p2pkhScriptCode(Hex.decode("11".repeat(20)));
    Transaction tx =
        new Transaction(
            2,
            List.of(
                new TxIn(new OutPoint(Hex.decode("aa".repeat(32)), 0), new byte[0], 10),
                new TxIn(new OutPoint(Hex.decode("bb".repeat(32)), 1), new byte[0], 20)),
            List.of(new TxOut(10, new byte[] {0x51}), new TxOut(20, new byte[] {0x52})),
            0,
            List.of(List.of(), List.of()));
    WitnessSighash.Cache cache = WitnessSighash.Cache.forTransaction(tx);
    for (int sighashType : List.of(1, 2, 3, 0x81, 0x82, 0x83)) {
      assertArrayEquals(
          WitnessSighash.bip143Sighash(tx, 1, scriptCode, 60_000, sighashType),
          WitnessSighash.bip143Sighash(tx, 1, scriptCode, 60_000, sighashType, cache));
    }
  }
}
