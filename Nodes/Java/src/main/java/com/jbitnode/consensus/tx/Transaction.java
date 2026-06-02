package com.jbitnode.consensus.tx;

import java.util.Arrays;
import java.util.List;

/** Parsed Bitcoin transaction (witness optional). */
public record Transaction(
    int version,
    List<TxIn> inputs,
    List<TxOut> outputs,
    long lockTime,
    List<List<byte[]>> witness) {

  private static final long COINBASE_INDEX = 0xffff_ffffL;

  public boolean isCoinbase() {
    if (inputs.size() != 1) {
      return false;
    }
    TxIn input = inputs.getFirst();
    return Arrays.equals(input.previousOutput().hash(), new byte[32])
        && input.previousOutput().index() == COINBASE_INDEX;
  }
}
