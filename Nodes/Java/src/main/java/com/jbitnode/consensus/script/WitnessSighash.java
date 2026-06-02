package com.jbitnode.consensus.script;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.wire.WireSerialize;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

/** BIP143 witness transaction sighash for P2WPKH/P2WSH spend verification. */
public final class WitnessSighash {

  private static final byte[] ZERO_HASH = new byte[32];

  private WitnessSighash() {}

  public static final class Cache {
    private final byte[] hashPrevouts;
    private final byte[] hashSequence;
    private final byte[] hashOutputsAll;

    private Cache(byte[] hashPrevouts, byte[] hashSequence, byte[] hashOutputsAll) {
      this.hashPrevouts = hashPrevouts;
      this.hashSequence = hashSequence;
      this.hashOutputsAll = hashOutputsAll;
    }

    public static Cache forTransaction(Transaction transaction) {
      return new Cache(
          hashPrevouts(transaction),
          hashSequence(transaction),
          hashOutputsAll(transaction));
    }
  }

  public static byte[] bip143Sighash(
      Transaction transaction, int inputIndex, byte[] scriptCode, long amount, int sighashType) {
    return bip143Sighash(transaction, inputIndex, scriptCode, amount, sighashType, null);
  }

  public static byte[] bip143Sighash(
      Transaction transaction,
      int inputIndex,
      byte[] scriptCode,
      long amount,
      int sighashType,
      Cache cache) {
    return ScriptVerifyProfiler.measure(
        "script_sighash_witness",
        () -> bip143SighashUnprofiled(transaction, inputIndex, scriptCode, amount, sighashType, cache));
  }

  static byte[] bip143SighashUnprofiled(
      Transaction transaction,
      int inputIndex,
      byte[] scriptCode,
      long amount,
      int sighashType,
      Cache cache) {
    if (inputIndex >= transaction.inputs().size()) {
      throw new IllegalArgumentException("input_index out of range");
    }

    boolean anyoneCanPay = (sighashType & 0x80) != 0;
    int baseType = sighashType & 0x1f;

    Cache effectiveCache = cache != null ? cache : Cache.forTransaction(transaction);
    byte[] hashPrevouts = anyoneCanPay ? ZERO_HASH : effectiveCache.hashPrevouts;
    byte[] hashSequence =
        !anyoneCanPay && baseType != 2 && baseType != 3
            ? effectiveCache.hashSequence
            : ZERO_HASH;

    byte[] hashOutputs = ZERO_HASH;
    if (baseType == 3) {
      if (inputIndex < transaction.outputs().size()) {
        hashOutputs =
            WireSerialize.doubleSha256(
                LegacySighash.serializeTxOut(transaction.outputs().get(inputIndex)));
      }
    } else if (baseType != 2) {
      hashOutputs = effectiveCache.hashOutputsAll;
    }

    TxIn txIn = transaction.inputs().get(inputIndex);
    ByteArrayOutputStream payload = new ByteArrayOutputStream();
    try {
      payload.write(WireSerialize.packInt32Le(transaction.version()));
      payload.write(hashPrevouts);
      payload.write(hashSequence);
      payload.write(LegacySighash.serializeOutPoint(txIn.previousOutput()));
      payload.write(WireSerialize.writeCompactSize(scriptCode.length));
      payload.write(scriptCode);
      payload.write(WireSerialize.packInt64Le(amount));
      payload.write(WireSerialize.packInt32Le((int) txIn.sequence()));
      payload.write(hashOutputs);
      payload.write(WireSerialize.packInt32Le((int) transaction.lockTime()));
      payload.write(WireSerialize.packInt32Le(sighashType));
    } catch (IOException error) {
      throw new IllegalStateException("bip143 sighash serialization failed", error);
    }
    return WireSerialize.doubleSha256(payload.toByteArray());
  }

  private static byte[] hashPrevouts(Transaction transaction) {
    ByteArrayOutputStream prevouts = new ByteArrayOutputStream();
    for (TxIn input : transaction.inputs()) {
      try {
        prevouts.write(LegacySighash.serializeOutPoint(input.previousOutput()));
      } catch (IOException error) {
        throw new IllegalStateException("prevouts serialization failed", error);
      }
    }
    return WireSerialize.doubleSha256(prevouts.toByteArray());
  }

  private static byte[] hashSequence(Transaction transaction) {
    ByteArrayOutputStream sequences = new ByteArrayOutputStream();
    for (TxIn input : transaction.inputs()) {
      try {
        sequences.write(WireSerialize.packInt32Le((int) input.sequence()));
      } catch (IOException error) {
        throw new IllegalStateException("sequence serialization failed", error);
      }
    }
    return WireSerialize.doubleSha256(sequences.toByteArray());
  }

  private static byte[] hashOutputsAll(Transaction transaction) {
    ByteArrayOutputStream outputs = new ByteArrayOutputStream();
    for (TxOut output : transaction.outputs()) {
      try {
        outputs.write(LegacySighash.serializeTxOut(output));
      } catch (IOException error) {
        throw new IllegalStateException("outputs serialization failed", error);
      }
    }
    return WireSerialize.doubleSha256(outputs.toByteArray());
  }
}
