package com.jbitnode.consensus.tx;

import com.jbitnode.wire.WireSerialize;
import com.jbitnode.wire.WireSerialize.CompactSizeResult;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Deserializes raw transaction bytes (BIP141 witness when present). */
public final class TransactionParser {

  public static final byte[] WITNESS_MARKER = {0x00, 0x01};

  private TransactionParser() {}

  public record ParseResult(Transaction transaction, int nextOffset) {}

  public static ParseResult deserialize(byte[] data, int offset) {
    int start = offset;
    int version = WireSerialize.unpackInt32Le(data, offset);
    offset += 4;
    boolean witnessFlag = false;
    if (offset + 1 < data.length
        && data[offset] == WITNESS_MARKER[0]
        && data[offset + 1] == WITNESS_MARKER[1]) {
      witnessFlag = true;
      offset += 2;
    }
    CompactSizeResult inputCount = WireSerialize.readCompactSize(data, offset);
    offset = inputCount.nextOffset();
    List<TxIn> inputs = new ArrayList<>();
    for (int index = 0; index < inputCount.value(); index++) {
      byte[] prevHash = Arrays.copyOfRange(data, offset, offset + 32);
      offset += 32;
      long inputIndex = WireSerialize.unpackUint32Le(data, offset);
      offset += 4;
      CompactSizeResult scriptLen = WireSerialize.readCompactSize(data, offset);
      offset = scriptLen.nextOffset();
      byte[] scriptSig = Arrays.copyOfRange(data, offset, offset + (int) scriptLen.value());
      offset += (int) scriptLen.value();
      long sequence = Integer.toUnsignedLong(WireSerialize.unpackInt32Le(data, offset));
      offset += 4;
      inputs.add(
          new TxIn(
              new OutPoint(prevHash, inputIndex),
              scriptSig,
              sequence));
    }
    CompactSizeResult outputCount = WireSerialize.readCompactSize(data, offset);
    offset = outputCount.nextOffset();
    List<TxOut> outputs = new ArrayList<>();
    for (int index = 0; index < outputCount.value(); index++) {
      long value = WireSerialize.unpackInt64Le(data, offset);
      offset += 8;
      CompactSizeResult scriptLen = WireSerialize.readCompactSize(data, offset);
      offset = scriptLen.nextOffset();
      byte[] scriptPubKey =
          Arrays.copyOfRange(data, offset, offset + (int) scriptLen.value());
      offset += (int) scriptLen.value();
      outputs.add(new TxOut(value, scriptPubKey));
    }
    List<List<byte[]>> witness = new ArrayList<>();
    if (witnessFlag) {
      for (int index = 0; index < inputCount.value(); index++) {
        CompactSizeResult stackCount = WireSerialize.readCompactSize(data, offset);
        offset = stackCount.nextOffset();
        List<byte[]> stack = new ArrayList<>();
        for (int stackIndex = 0; stackIndex < stackCount.value(); stackIndex++) {
          CompactSizeResult itemLen = WireSerialize.readCompactSize(data, offset);
          offset = itemLen.nextOffset();
          stack.add(Arrays.copyOfRange(data, offset, offset + (int) itemLen.value()));
          offset += (int) itemLen.value();
        }
        witness.add(List.copyOf(stack));
      }
    }
    long lockTime = Integer.toUnsignedLong(WireSerialize.unpackInt32Le(data, offset));
    offset += 4;
    if (offset < start) {
      throw new IllegalArgumentException("transaction deserialization underflow");
    }
    return new ParseResult(
        new Transaction(version, List.copyOf(inputs), List.copyOf(outputs), lockTime, witness),
        offset);
  }
}
