package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class TapscriptTest {

  @Test
  void prescanOpSuccessDetectsSuccessOpcode() {
    assertTrue(Tapscript.prescanOpSuccess(new byte[] {(byte) 0x50}));
    assertFalse(Tapscript.prescanOpSuccess(new byte[] {(byte) OpCodes.OP_CHECKSIG}));
  }

  @Test
  void acceptsSyntheticScriptPathOp1Spend() {
    BigInteger secret = BigInteger.valueOf(11);
    byte[] internalXonly = xonlyFromSecret(secret);
    byte[] tapscript = new byte[] {(byte) OpCodes.OP_1};
    byte[] leafDigest = TaprootHash.tapleafHash(0xc0, tapscript);
    byte[] merkleRoot = TaprootHash.taprootMerkleRootFromBranch(List.of(), leafDigest);
    Secp256k1.TaprootTweakResult tweak =
        Secp256k1.taprootTweakPubkeyXonly(internalXonly, merkleRoot);
    byte[] prevSpk = concat(new byte[] {(byte) OpCodes.OP_1, 32}, tweak.outputXonly());
    byte[] controlBlock =
        concat(new byte[] {(byte) (0xc0 | tweak.parity())}, internalXonly);

    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of(List.of(tapscript, controlBlock)));
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));

    assertTrue(
        Taproot.verifyTaprootSpend(
            prevSpk, new byte[0], tx.witness().getFirst(), tx, 0, prevouts));
  }

  @Test
  void rejectsMerkleMismatch() {
    BigInteger secret = BigInteger.valueOf(13);
    byte[] internalXonly = xonlyFromSecret(secret);
    byte[] tapscript = new byte[] {(byte) OpCodes.OP_1};
    byte[] leafDigest = TaprootHash.tapleafHash(0xc0, tapscript);
    byte[] merkleRoot = TaprootHash.taprootMerkleRootFromBranch(List.of(), leafDigest);
    Secp256k1.TaprootTweakResult tweak =
        Secp256k1.taprootTweakPubkeyXonly(internalXonly, merkleRoot);
    byte[] prevSpk = concat(new byte[] {(byte) OpCodes.OP_1, 32}, tweak.outputXonly());
    byte[] wrongInternal = Arrays.copyOf(internalXonly, internalXonly.length);
    wrongInternal[0] ^= 0x01;
    byte[] controlBlock = concat(new byte[] {(byte) (0xc0 | tweak.parity())}, wrongInternal);

    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of(List.of(tapscript, controlBlock)));
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));

    assertFalse(
        Taproot.verifyTaprootSpend(
            prevSpk, new byte[0], tx.witness().getFirst(), tx, 0, prevouts));
  }

  @Test
  void acceptsNonTapscriptLeafWithoutExecution() {
    BigInteger secret = BigInteger.valueOf(17);
    byte[] internalXonly = xonlyFromSecret(secret);
    byte[] tapscript = concat(new byte[] {(byte) 0xff}, new byte[200]);
    int leafVersion = 0xc2;
    byte[] leafDigest = TaprootHash.tapleafHash(leafVersion, tapscript);
    byte[] merkleRoot = TaprootHash.taprootMerkleRootFromBranch(List.of(), leafDigest);
    Secp256k1.TaprootTweakResult tweak =
        Secp256k1.taprootTweakPubkeyXonly(internalXonly, merkleRoot);
    byte[] prevSpk = concat(new byte[] {(byte) OpCodes.OP_1, 32}, tweak.outputXonly());
    byte[] controlBlock =
        concat(new byte[] {(byte) (leafVersion | tweak.parity())}, internalXonly);

    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of(List.of(tapscript, controlBlock)));
    List<ScriptVerify.SpentPrevout> prevouts =
        List.of(new ScriptVerify.SpentPrevout(1000, prevSpk));

    assertTrue(
        Taproot.verifyTaprootSpend(
            prevSpk, new byte[0], tx.witness().getFirst(), tx, 0, prevouts));
  }

  @Test
  void tapscriptIfElseSkipsInactiveBranch() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            100,
            List.of());
    byte[] script =
        new byte[] {
          (byte) OpCodes.OP_IF,
          (byte) OpCodes.OP_1,
          (byte) OpCodes.OP_ELSE,
          (byte) OpCodes.OP_0,
          (byte) OpCodes.OP_ENDIF
        };
    Tapscript.evaluate(
        script,
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertTrue(ScriptInterpreter.terminalSuccessStrict(stack));
  }

  @Test
  void tapscriptRejectsUnbalancedConditional() {
    ScriptStack stack = new ScriptStack();
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    assertThrows(
        ScriptError.class,
        () ->
            Tapscript.evaluate(
                new byte[] {(byte) OpCodes.OP_ENDIF},
                stack,
                tx,
                0,
                new byte[32],
                List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
                null,
                new int[] {1000}));
  }

  @Test
  void tapscriptNipRemovesSecondFromTop() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("010203"));
    stack.push(Hex.decode("aa"));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_NIP},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertEquals(1, stack.size());
    assertTrue(Arrays.equals(Hex.decode("aa"), stack.peek()));
  }

  @Test
  void tapscriptSha256HashesStackItem() {
    byte[] preimage = Hex.decode("0102030405");
    ScriptStack stack = new ScriptStack();
    stack.push(preimage);
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_SHA256},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertEquals(1, stack.size());
    assertTrue(Arrays.equals(ScriptHash.sha256(preimage), stack.peek()));
  }

  @Test
  void tapscriptNumequalComparesScriptNumbers() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(2, 4));
    stack.push(ScriptNum.encodeScriptNum(2, 4));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_NUMEQUAL},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertTrue(ScriptInterpreter.castToBool(stack.peek()));

    stack.pop();
    stack.push(ScriptNum.encodeScriptNum(3, 4));
    stack.push(ScriptNum.encodeScriptNum(2, 4));
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_NUMNOTEQUAL},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertTrue(ScriptInterpreter.castToBool(stack.peek()));
  }

  @Test
  void tapscriptWithinChecksMinInclusiveMaxExclusiveRange() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(69, 4));
    stack.push(ScriptNum.encodeScriptNum(61, 4));
    stack.push(ScriptNum.encodeScriptNum(70, 4));
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0L)),
            List.of(new TxOut(1, new byte[] {0x51})),
            0,
            List.of());
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_WITHIN},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertTrue(ScriptInterpreter.castToBool(stack.pop()));

    stack.push(ScriptNum.encodeScriptNum(70, 4));
    stack.push(ScriptNum.encodeScriptNum(61, 4));
    stack.push(ScriptNum.encodeScriptNum(70, 4));
    Tapscript.evaluate(
        new byte[] {(byte) OpCodes.OP_WITHIN},
        stack,
        tx,
        0,
        new byte[32],
        List.of(new ScriptVerify.SpentPrevout(1, new byte[] {0x51})),
        null,
        new int[] {1000});
    assertFalse(ScriptInterpreter.castToBool(stack.pop()));
  }

  @Test
  void scriptNumRoundTrip() {
    assertTrue(ScriptNum.decodeScriptNum(ScriptNum.encodeScriptNum(3, 4), 4) == 3);
    assertTrue(ScriptNum.decodeScriptNum(ScriptNum.encodeScriptNum(-2, 4), 4) == -2);
  }

  private static byte[] xonlyFromSecret(BigInteger secret) {
    return Arrays.copyOfRange(Secp256k1.testPubkeySec1(secret), 1, 33);
  }

  private static byte[] concat(byte[] left, byte[] right) {
    byte[] out = new byte[left.length + right.length];
    System.arraycopy(left, 0, out, 0, left.length);
    System.arraycopy(right, 0, out, left.length, right.length);
    return out;
  }
}
