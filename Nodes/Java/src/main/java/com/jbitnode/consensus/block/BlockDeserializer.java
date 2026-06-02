package com.jbitnode.consensus.block;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TransactionParser;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.wire.WireSerialize;
import com.jbitnode.wire.WireSerialize.CompactSizeResult;
import java.util.ArrayList;
import java.util.List;

/** Deserializes a raw block payload (header + tx vector). */
public final class BlockDeserializer {

  public static final byte[] BLOCK_WITNESS_MARKER = {0x00, 0x01};

  private BlockDeserializer() {}

  public static Block deserialize(byte[] payload) {
    BlockHeader header = BlockHeaderCodec.deserialize(payload, 0);
    int offset = BlockHeaderCodec.HEADER_SIZE;
    CompactSizeResult txCount = WireSerialize.readCompactSize(payload, offset);
    offset = txCount.nextOffset();
    if (offset + 1 < payload.length
        && payload[offset] == BLOCK_WITNESS_MARKER[0]
        && payload[offset + 1] == BLOCK_WITNESS_MARKER[1]) {
      offset += 2;
    }
    List<Transaction> transactions = new ArrayList<>();
    for (int index = 0; index < txCount.value(); index++) {
      TransactionParser.ParseResult parsed = TransactionParser.deserialize(payload, offset);
      transactions.add(parsed.transaction());
      offset = parsed.nextOffset();
    }
    if (offset != payload.length) {
      throw new IllegalArgumentException(
          "trailing block bytes: " + (payload.length - offset));
    }
    return new Block(header, List.copyOf(transactions));
  }
}
