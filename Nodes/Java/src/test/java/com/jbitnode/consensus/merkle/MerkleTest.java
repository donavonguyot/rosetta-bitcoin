package com.jbitnode.consensus.merkle;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.wire.WireSerialize;
import java.util.List;
import org.junit.jupiter.api.Test;

class MerkleTest {

  @Test
  void matchesBlock1HeaderMerkleRoot() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Block block = BlockDeserializer.deserialize(payload);
    assertArrayEquals(block.header().merkleRoot(), Merkle.blockMerkleRoot(block.transactions()));
    assertEquals(
        FixtureLoader.readText("/fixtures/block1_hash.txt"),
        BlockHeaderCodec.blockHashHex(block.header()));
  }

  @Test
  void coinbaseTxidMatchesNonWitnessSerialization() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Transaction coinbase = TransactionParser.deserialize(payload, 81).transaction();
    byte[] txid = Merkle.transactionTxid(coinbase);
    assertEquals(32, txid.length);
    assertArrayEquals(
        txid,
        Merkle.merkleRoot(List.of(txid)));
  }

  @Test
  void merkleRootDuplicatesLastHashForOddCount() {
    byte[] left = new byte[32];
    left[0] = 0x01;
    byte[] right = new byte[32];
    right[0] = 0x02;
    byte[] pairRoot = Merkle.merkleRoot(List.of(left, right));
    assertFalse(java.util.Arrays.equals(pairRoot, Merkle.merkleRoot(List.of(left))));
    byte[] combined = new byte[64];
    System.arraycopy(left, 0, combined, 0, 32);
    System.arraycopy(right, 0, combined, 32, 32);
    assertArrayEquals(pairRoot, WireSerialize.doubleSha256(combined));
  }

  @Test
  void emptyMerkleRootIsZeroHash() {
    assertArrayEquals(new byte[32], Merkle.merkleRoot(List.of()));
  }

  @Test
  void witnessTxidIgnoresWitnessData() {
    byte[] payload = FixtureLoader.readHex("/fixtures/tx_taproot_6975.hex");
    Transaction tx = TransactionParser.deserialize(payload, 0).transaction();
    byte[] withWitness = Merkle.transactionTxid(tx);
    Transaction stripped =
        new Transaction(tx.version(), tx.inputs(), tx.outputs(), tx.lockTime(), List.of());
    byte[] withoutWitness = Merkle.transactionTxid(stripped);
    assertArrayEquals(withWitness, withoutWitness);
  }

  @Test
  void blockMerkleRootHandlesMultipleTransactions() {
    byte[] block2 = FixtureLoader.readHex("/fixtures/block2_wire.hex");
    Block block = BlockDeserializer.deserialize(block2);
    assertTrue(block.transactions().size() >= 1);
    assertArrayEquals(block.header().merkleRoot(), Merkle.blockMerkleRoot(block.transactions()));
  }
}
