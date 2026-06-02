package com.jbitnode.sync;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.consensus.merkle.Merkle;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.util.Hex;
import java.util.Arrays;

/** Independent block payload checks before connect (header link, hash, merkle). */
public final class BlockValidator {

  public static final int MAX_BLOCK_PAYLOAD_BYTES = 4_000_000;
  public static final int MIN_BLOCK_PAYLOAD_BYTES = 80;

  private BlockValidator() {}

  public record ValidateOptions(byte[] expectedPrev, byte[] expectedHash) {}

  public static Block validateBlock(byte[] payload, ValidateOptions options)
      throws BlockValidationException {
    if (payload.length < MIN_BLOCK_PAYLOAD_BYTES) {
      throw new BlockValidationException("block payload too small: " + payload.length + " bytes");
    }
    if (payload.length > MAX_BLOCK_PAYLOAD_BYTES) {
      throw new BlockValidationException("block payload too large: " + payload.length + " bytes");
    }

    Block block;
    try {
      block = BlockDeserializer.deserialize(payload);
    } catch (RuntimeException error) {
      throw new BlockValidationException(error.getMessage(), error);
    }

    BlockHeader header = block.header();
    if (!Arrays.equals(header.prevBlock(), options.expectedPrev())) {
      throw new BlockValidationException(
          "prev_block mismatch: expected "
              + Hex.encode(Hex.reverse(options.expectedPrev()))
              + ", got "
              + Hex.encode(Hex.reverse(header.prevBlock())));
    }

    if (options.expectedHash() != null) {
      byte[] actualHash = BlockHeaderCodec.blockHash(header);
      if (!Arrays.equals(actualHash, options.expectedHash())) {
        throw new BlockValidationException(
            "block hash mismatch: expected "
                + Hex.encode(Hex.reverse(options.expectedHash()))
                + ", got "
                + BlockHeaderCodec.blockHashHex(header));
      }
    }

    if (block.transactions().isEmpty()) {
      throw new BlockValidationException("block has no transactions");
    }

    if (!block.transactions().getFirst().isCoinbase()) {
      throw new BlockValidationException("first transaction must be coinbase");
    }

    byte[] merkleRoot = Merkle.blockMerkleRoot(block.transactions());
    if (!Arrays.equals(merkleRoot, header.merkleRoot())) {
      throw new BlockValidationException(
          "merkle root mismatch: expected "
              + Hex.encode(Hex.reverse(header.merkleRoot()))
              + ", computed "
              + Hex.encode(Hex.reverse(merkleRoot)));
    }

    return block;
  }

  public static boolean isCoinbaseOnlyBlock(Block block) {
    return block.transactions().size() == 1 && block.transactions().getFirst().isCoinbase();
  }
}
