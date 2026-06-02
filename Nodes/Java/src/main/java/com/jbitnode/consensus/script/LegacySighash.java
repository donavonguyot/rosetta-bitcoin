package com.jbitnode.consensus.script;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.wire.WireSerialize;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Arrays;

/** Legacy (pre-segwit) transaction sighash for P2PK/P2PKH script verification. */
public final class LegacySighash {

  /** Core {@code CTxOut()} placeholder for SIGHASH_SINGLE indices {@code < nIn}. */
  static final TxOut SIGHASH_SINGLE_PLACEHOLDER_OUTPUT = new TxOut(-1, new byte[0]);

  private LegacySighash() {}

  public static byte[] legacySighash(
      Transaction transaction, int inputIndex, byte[] scriptCode, int sighashType) {
    return ScriptVerifyProfiler.measure(
        "script_sighash_legacy",
        () -> legacySighashUnprofiled(transaction, inputIndex, scriptCode, sighashType));
  }

  static byte[] legacySighashUnprofiled(
      Transaction transaction, int inputIndex, byte[] scriptCode, int sighashType) {
    if (inputIndex >= transaction.inputs().size()) {
      throw new IllegalArgumentException("input_index out of range");
    }

    int baseType = sighashType & 0x1f;
    boolean anyoneCanPay = (sighashType & 0x80) != 0;

    if (baseType == 3 && inputIndex >= transaction.outputs().size()) {
      // Core uint256::ONE (256-bit little-endian integer 1).
      byte[] out = new byte[32];
      out[0] = 0x01;
      return out;
    }

    ByteArrayOutputStream parts = new ByteArrayOutputStream();
    try {
      parts.write(WireSerialize.packInt32Le(transaction.version()));

      if (anyoneCanPay) {
        parts.write(WireSerialize.writeCompactSize(1));
        writeInput(parts, transaction.inputs().get(inputIndex), inputIndex, scriptCode, baseType, true);
      } else {
        parts.write(WireSerialize.writeCompactSize(transaction.inputs().size()));
        for (int index = 0; index < transaction.inputs().size(); index++) {
          writeInput(
              parts,
              transaction.inputs().get(index),
              inputIndex,
              scriptCode,
              baseType,
              index == inputIndex);
        }
      }

      if (baseType == 2) {
        parts.write(WireSerialize.writeCompactSize(0));
      } else if (baseType == 3) {
        // Core RawSignatureHash: outputs before the signed index are empty placeholders.
        parts.write(WireSerialize.writeCompactSize(inputIndex + 1));
        for (int index = 0; index < inputIndex; index++) {
          parts.write(serializeTxOut(SIGHASH_SINGLE_PLACEHOLDER_OUTPUT));
        }
        parts.write(serializeTxOut(transaction.outputs().get(inputIndex)));
      } else {
        parts.write(WireSerialize.writeCompactSize(transaction.outputs().size()));
        for (TxOut output : transaction.outputs()) {
          parts.write(serializeTxOut(output));
        }
      }

      parts.write(WireSerialize.packInt32Le((int) transaction.lockTime()));
      parts.write(WireSerialize.packInt32Le(sighashType));
    } catch (IOException error) {
      throw new IllegalStateException("legacy sighash serialization failed", error);
    }
    return WireSerialize.doubleSha256(parts.toByteArray());
  }

  /** Pre-hash preimage bytes (tests and cross-checks against Core). */
  static byte[] legacySighashPreimage(
      Transaction transaction, int inputIndex, byte[] scriptCode, int sighashType) {
    if (inputIndex >= transaction.inputs().size()) {
      throw new IllegalArgumentException("input_index out of range");
    }

    int baseType = sighashType & 0x1f;
    boolean anyoneCanPay = (sighashType & 0x80) != 0;

    if (baseType == 3 && inputIndex >= transaction.outputs().size()) {
      return new byte[0];
    }

    ByteArrayOutputStream parts = new ByteArrayOutputStream();
    try {
      parts.write(WireSerialize.packInt32Le(transaction.version()));

      if (anyoneCanPay) {
        parts.write(WireSerialize.writeCompactSize(1));
        writeInput(parts, transaction.inputs().get(inputIndex), inputIndex, scriptCode, baseType, true);
      } else {
        parts.write(WireSerialize.writeCompactSize(transaction.inputs().size()));
        for (int index = 0; index < transaction.inputs().size(); index++) {
          writeInput(
              parts,
              transaction.inputs().get(index),
              inputIndex,
              scriptCode,
              baseType,
              index == inputIndex);
        }
      }

      if (baseType == 2) {
        parts.write(WireSerialize.writeCompactSize(0));
      } else if (baseType == 3) {
        parts.write(WireSerialize.writeCompactSize(inputIndex + 1));
        for (int index = 0; index < inputIndex; index++) {
          parts.write(serializeTxOut(SIGHASH_SINGLE_PLACEHOLDER_OUTPUT));
        }
        parts.write(serializeTxOut(transaction.outputs().get(inputIndex)));
      } else {
        parts.write(WireSerialize.writeCompactSize(transaction.outputs().size()));
        for (TxOut output : transaction.outputs()) {
          parts.write(serializeTxOut(output));
        }
      }

      parts.write(WireSerialize.packInt32Le((int) transaction.lockTime()));
      parts.write(WireSerialize.packInt32Le(sighashType));
    } catch (IOException error) {
      throw new IllegalStateException("legacy sighash serialization failed", error);
    }
    return parts.toByteArray();
  }

  private static void writeInput(
      ByteArrayOutputStream out,
      TxIn input,
      int inputIndex,
      byte[] scriptCode,
      int baseType,
      boolean signingInput)
      throws IOException {
    out.write(input.previousOutput().hash());
    out.write(WireSerialize.packUint32Le(input.previousOutput().index()));
    if (signingInput) {
      out.write(WireSerialize.writeCompactSize(scriptCode.length));
      out.write(scriptCode);
    } else {
      out.write(new byte[] {0x00});
    }
    // SIGHASH_NONE/SINGLE: only non-signing inputs get sequence 0 (Core RawSignatureHash).
    if (baseType == 1 || signingInput) {
      out.write(WireSerialize.packUint32Le(input.sequence()));
    } else {
      out.write(new byte[4]);
    }
  }

  static byte[] serializeTxOut(TxOut output) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try {
      out.write(WireSerialize.packInt64Le(output.value()));
      out.write(WireSerialize.writeCompactSize(output.scriptPubKey().length));
      out.write(output.scriptPubKey());
    } catch (IOException error) {
      throw new IllegalStateException("txout serialization failed", error);
    }
    return out.toByteArray();
  }

  static byte[] serializeOutPoint(OutPoint outPoint) {
    byte[] out = new byte[36];
    System.arraycopy(outPoint.hash(), 0, out, 0, 32);
    System.arraycopy(WireSerialize.packUint32Le(outPoint.index()), 0, out, 32, 4);
    return out;
  }
}
