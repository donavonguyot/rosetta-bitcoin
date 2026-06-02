package com.jbitnode.sync;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import com.jbitnode.chain.Genesis;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.testutil.FixtureLoader;
import com.jbitnode.util.Hex;
import org.junit.jupiter.api.Test;

class BlockValidatorTest {

  @Test
  void validatesCommittedBlockFixture() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Block block = BlockDeserializer.deserialize(payload);
    byte[] expectedHash = Hex.reverse(Hex.decode(FixtureLoader.readText("/fixtures/block1_hash.txt")));
    Block validated =
        BlockValidator.validateBlock(
            payload,
            new BlockValidator.ValidateOptions(
                BlockHeaderCodec.blockHash(Genesis.TESTNET4), expectedHash));
    assertEquals(1, validated.transactions().size());
    assertTrue(BlockValidator.isCoinbaseOnlyBlock(validated));
  }

  @Test
  void rejectsHashMismatch() {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    assertThrows(
        BlockValidationException.class,
        () ->
            BlockValidator.validateBlock(
                payload,
                new BlockValidator.ValidateOptions(
                    BlockHeaderCodec.blockHash(Genesis.TESTNET4), new byte[32])));
  }

  @Test
  void rejectsSmallPayloadAndEmptyTransactions() {
    assertThrows(
        BlockValidationException.class,
        () ->
            BlockValidator.validateBlock(
                new byte[32],
                new BlockValidator.ValidateOptions(
                    BlockHeaderCodec.blockHash(Genesis.TESTNET4), null)));
  }

  @Test
  void rejectsOversizedPayload() {
    byte[] payload = new byte[BlockValidator.MAX_BLOCK_PAYLOAD_BYTES + 1];
    assertThrows(
        BlockValidationException.class,
        () ->
            BlockValidator.validateBlock(
                payload,
                new BlockValidator.ValidateOptions(
                    BlockHeaderCodec.blockHash(Genesis.TESTNET4), null)));
  }

  @Test
  void detectsNonCoinbaseOnlyBlock() throws Exception {
    byte[] payload = FixtureLoader.readHex("/fixtures/block1_wire.hex");
    Block block = BlockDeserializer.deserialize(payload);
    assertTrue(BlockValidator.isCoinbaseOnlyBlock(block));
  }
}
