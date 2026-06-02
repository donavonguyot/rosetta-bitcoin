package com.jbitnode.consensus.tx;

import com.jbitnode.wire.WireSerialize;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.List;

/** Serializes transactions for txid / round-trip checks (witness optional). */
public final class TransactionSerializer {

  private TransactionSerializer() {}

  public static byte[] serialize(Transaction transaction, boolean includeWitness) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write(WireSerialize.packInt32Le(transaction.version()));
      boolean useWitness = includeWitness && !transaction.witness().isEmpty();
      if (useWitness) {
        out.write(TransactionParser.WITNESS_MARKER);
      }
      out.write(WireSerialize.writeCompactSize(transaction.inputs().size()));
      for (TxIn input : transaction.inputs()) {
        out.write(input.previousOutput().hash());
        out.write(WireSerialize.packUint32Le(input.previousOutput().index()));
        out.write(WireSerialize.writeCompactSize(input.scriptSig().length));
        out.write(input.scriptSig());
        out.write(WireSerialize.packInt32Le((int) input.sequence()));
      }
      out.write(WireSerialize.writeCompactSize(transaction.outputs().size()));
      for (TxOut output : transaction.outputs()) {
        out.write(WireSerialize.packInt64Le(output.value()));
        out.write(WireSerialize.writeCompactSize(output.scriptPubKey().length));
        out.write(output.scriptPubKey());
      }
      if (useWitness) {
        for (List<byte[]> stack : transaction.witness()) {
          out.write(WireSerialize.writeCompactSize(stack.size()));
          for (byte[] item : stack) {
            out.write(WireSerialize.writeCompactSize(item.length));
            out.write(item);
          }
        }
      }
      out.write(WireSerialize.packInt32Le((int) transaction.lockTime()));
    } catch (IOException e) {
      throw new IllegalStateException("transaction serialization failed", e);
    }
    return out.toByteArray();
  }
}
