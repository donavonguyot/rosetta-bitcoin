package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.util.Hex;
import java.util.List;
import org.junit.jupiter.api.Test;

class ScriptInterpreterTest {

  @Test
  void opDupDuplicatesTopItem() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x01});
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_DUP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(2, stack.size());
    assertArrayEquals(new byte[] {0x01}, stack.pop());
    assertArrayEquals(new byte[] {0x01}, stack.pop());
  }

  @Test
  void opHash160HashesTopItem() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[0]);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_HASH160)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertEquals("b472a266d0bd89c13706a4132ccfb16f7c3b9fcb", Hex.encode(stack.pop()));
  }

  @Test
  void opSha256HashesTopItem() {
    byte[] data = "810899055".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    ScriptStack stack = new ScriptStack();
    stack.push(data);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_SHA256)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(ScriptHash.sha256(data), stack.pop());
  }

  @Test
  void opRipemd160HashesTopItem() {
    byte[] sig = Hex.decode("300602010102010183");
    ScriptStack stack = new ScriptStack();
    stack.push(sig);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_RIPEMD160)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertEquals("32a8efa32f198f21b58d98919a25b0cbcb428d49", Hex.encode(stack.pop()));
  }

  @Test
  void opSha256EqualVerifyAcceptsMatchingDigest() {
    byte[] data = "810899055".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    byte[] digest = ScriptHash.sha256(data);
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("deadbeef"));
    stack.push(data);
    byte[] script =
        concat(
            new byte[] {op(OpCodes.OP_SHA256), (byte) digest.length},
            digest,
            new byte[] {op(OpCodes.OP_EQUALVERIFY)});
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(Hex.decode("deadbeef"), stack.pop());
  }

  @Test
  void opSwapExchangesTopTwoItems() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("0102"));
    stack.push(Hex.decode("0304"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_SWAP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(2, stack.size());
    assertArrayEquals(Hex.decode("0102"), stack.pop());
    assertArrayEquals(Hex.decode("0304"), stack.pop());
  }

  @Test
  void opRotRotatesTopThreeItems() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_ROT)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(3, stack.size());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
  }

  @Test
  void op2dupDuplicatesTopTwoItems() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_2DUP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(4, stack.size());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void op2swapSwapsTopTwoPairs() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    stack.push(Hex.decode("04"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_2SWAP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(4, stack.size());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("04"), stack.pop());
    assertArrayEquals(Hex.decode("03"), stack.pop());
  }

  @Test
  void op2overCopiesThirdAndFourthFromTop() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("05"));
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    stack.push(Hex.decode("04"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_2OVER)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(7, stack.size());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("04"), stack.pop());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("05"), stack.pop());
  }

  @Test
  void opDepthPushesStackSize() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_DEPTH)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(3, stack.size());
    assertArrayEquals(new byte[] {0x02}, stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void opPickCopiesNthItemFromTop() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    stack.push(new byte[] {0x01});
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_PICK)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(4, stack.size());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void opNipRemovesSecondFromTopItem() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_NIP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(2, stack.size());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void opOverCopiesSecondFromTopItem() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_OVER)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(3, stack.size());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void opToAltStackAndFromAltStackRoundTripTopItem() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_TOALTSTACK), op(OpCodes.OP_FROMALTSTACK)},
        stack,
        ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(2, stack.size());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void op3dupDuplicatesTopThreeItems() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    stack.push(Hex.decode("03"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_3DUP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(6, stack.size());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
    assertArrayEquals(Hex.decode("03"), stack.pop());
    assertArrayEquals(Hex.decode("02"), stack.pop());
    assertArrayEquals(Hex.decode("01"), stack.pop());
  }

  @Test
  void opAddPushesSumAsScriptNum() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(2, 4));
    stack.push(ScriptNum.encodeScriptNum(1, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_ADD)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertEquals(3, ScriptInterpreter.decodeScriptNum(stack.pop()));
  }

  @Test
  void opSubPushesDifferenceAsScriptNum() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(2024, 4));
    stack.push(ScriptNum.encodeScriptNum(2001, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_SUB)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertEquals(23, ScriptInterpreter.decodeScriptNum(stack.pop()));
  }

  @Test
  void opGreaterThanComparesScriptNums() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(23, 4));
    stack.push(ScriptNum.encodeScriptNum(18, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_GREATERTHAN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(ScriptInterpreter.encodeOpN(1), stack.pop());

    stack.push(ScriptNum.encodeScriptNum(23, 4));
    stack.push(ScriptNum.encodeScriptNum(24, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_GREATERTHAN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(0), stack.pop());
  }

  @Test
  void opWithinChecksMinInclusiveMaxExclusiveRange() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(69, 4));
    stack.push(ScriptNum.encodeScriptNum(61, 4));
    stack.push(ScriptNum.encodeScriptNum(70, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_WITHIN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(1), stack.pop());

    stack.push(ScriptNum.encodeScriptNum(60, 4));
    stack.push(ScriptNum.encodeScriptNum(61, 4));
    stack.push(ScriptNum.encodeScriptNum(70, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_WITHIN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(0), stack.pop());

    stack.push(ScriptNum.encodeScriptNum(70, 4));
    stack.push(ScriptNum.encodeScriptNum(61, 4));
    stack.push(ScriptNum.encodeScriptNum(70, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_WITHIN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(0), stack.pop());
  }

  @Test
  void opAbsPushesAbsoluteScriptNum() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(-5, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_ABS)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(5, ScriptInterpreter.decodeScriptNum(stack.pop()));
  }

  @Test
  void opLessThanComparesScriptNums() {
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(71, 4));
    stack.push(ScriptNum.encodeScriptNum(80, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_LESSTHAN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(1), stack.pop());

    stack.push(ScriptNum.encodeScriptNum(71, 4));
    stack.push(ScriptNum.encodeScriptNum(71, 4));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_LESSTHAN)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(ScriptInterpreter.encodeOpN(0), stack.pop());
  }

  @Test
  void opCodeSeparatorTruncatesEffectiveScriptCode() {
    byte[] fullScript = Hex.decode("0102030405");
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(null, 0, fullScript, 0, false);
    assertArrayEquals(fullScript, context.effectiveScriptCode());
    ScriptInterpreter.EvalContext truncated = context.withCodeSeparatorAfter(2);
    assertArrayEquals(Hex.decode("030405"), truncated.effectiveScriptCode());
  }

  @Test
  void opCodeSeparatorIsNoOpWithoutContext() {
    ScriptStack stack = new ScriptStack();
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CODESEPARATOR), op(OpCodes.OP_1)},
        stack,
        ScriptInterpreter.EvalOptions.withFlags(0));
    assertArrayEquals(ScriptInterpreter.encodeOpN(1), stack.peek());
  }

  @Test
  void opSizePushesTopItemLength() {
    byte[] data = "810899055".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    ScriptStack stack = new ScriptStack();
    stack.push(data);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_SIZE)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(2, stack.size());
    assertArrayEquals(data, stack.itemFromTop(2));
    assertEquals(9, ScriptInterpreter.decodeScriptNum(stack.peek()));
  }

  @Test
  void opEqualVerifyAcceptsMatchingItems() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("010203"));
    stack.push(Hex.decode("010203"));
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_EQUALVERIFY)},
        stack,
        ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(stack.isEmpty());
  }

  @Test
  void opEqualVerifyRejectsMismatch() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    stack.push(Hex.decode("02"));
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_EQUALVERIFY)},
                stack,
                ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void p2pkhTemplateShapeExecutesThroughHash160() {
    byte[] preimage = Hex.decode("01020304");
    byte[] pubkeyHash = ScriptHash.hash160(preimage);
    byte[] script =
        concat(
            new byte[] {op(OpCodes.OP_DUP), op(OpCodes.OP_HASH160), (byte) pubkeyHash.length},
            pubkeyHash,
            new byte[] {op(OpCodes.OP_EQUALVERIFY), op(OpCodes.OP_CHECKSIG)});
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {(byte) 0x01});
    stack.push(preimage);
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(ScriptInterpreter.encodeOpN(0), stack.pop());
  }

  @Test
  void opChecksigVerifyFailsWithStubSignature() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x01});
    stack.push(new byte[] {0x02});
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSIGVERIFY)},
                stack,
                ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void cltvNoOpsWithoutVerifyFlag() {
    ScriptStack stack = new ScriptStack();
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
        stack,
        ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(stack.isEmpty());
  }

  @Test
  void cltvAcceptsSatisfiedHeightLock() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xfffffffeL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            100,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(100, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
        stack,
        context,
        ScriptInterpreter.EvalOptions.withFlags(
            ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY));
    assertEquals(1, stack.size());
  }

  @Test
  void cltvRejectsUnsatisfiedLocktime() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xfffffffeL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            100,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(200, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
                stack,
                context,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY)));
  }

  @Test
  void cltvRejectsFinalTransaction() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            100,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(100, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
                stack,
                context,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY)));
  }

  @Test
  void cltvNoOpsOnVersionOneTransaction() {
    Transaction tx =
        new Transaction(
            1,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xfffffffeL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            100,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(100, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
        stack,
        context,
        ScriptInterpreter.EvalOptions.withFlags(
            ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY));
    assertEquals(1, stack.size());
  }

  @Test
  void cltvRejectsLocktimeTypeMismatch() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xfffffffeL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            500_000_000,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(100, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
                stack,
                context,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY)));
  }

  @Test
  void cltvRejectsEmptyStackAndMissingContext() {
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
                new ScriptStack(),
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY)));

    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(100, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)},
                stack,
                null,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKLOCKTIMEVERIFY)));
  }

  @Test
  void csvAcceptsSatisfiedRelativeLock() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 10)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
        stack,
        context,
        ScriptInterpreter.EvalOptions.withFlags(
            ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY));
    assertEquals(1, stack.size());
  }

  @Test
  void csvRejectsUnsatisfiedSequence() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 5)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
                stack,
                context,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY)));
  }

  @Test
  void csvRejectsFinalSequenceAndDisabledFlag() {
    Transaction finalSeqTx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(finalSeqTx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
                stack,
                context,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY)));

    Transaction disabledTx =
        new Transaction(
            2,
            List.of(
                new TxIn(
                    new OutPoint(new byte[32], 0),
                    new byte[0],
                    0x8000_0000L | 10)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack disabledStack = new ScriptStack();
    disabledStack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext disabledContext =
        new ScriptInterpreter.EvalContext(disabledTx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
                disabledStack,
                disabledContext,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY)));
  }

  @Test
  void csvIsNoOpWhenStackOperandHasDisableFlag() {
    Transaction tx =
        new Transaction(
            2,
            List.of(
                new TxIn(
                    new OutPoint(new byte[32], 0),
                    new byte[0],
                    0x8000_0001L)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x01, 0x00, 0x00, (byte) 0x80, 0x00});
    ScriptInterpreter.EvalContext context =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
        stack,
        context,
        ScriptInterpreter.EvalOptions.withFlags(
            ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY));
    assertEquals(1, stack.size());
  }

  @Test
  void csvRejectsTypeMismatchAndMissingContext() {
    Transaction tx =
        new Transaction(
            2,
            List.of(new TxIn(new OutPoint(new byte[32], 0), new byte[0], 1 << 22)),
            List.of(new TxOut(900, new byte[] {0x51})),
            0,
            List.of());
    ScriptStack mismatchStack = new ScriptStack();
    mismatchStack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    ScriptInterpreter.EvalContext mismatchContext =
        new ScriptInterpreter.EvalContext(tx, 0, new byte[0], 0, false);
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
                mismatchStack,
                mismatchContext,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY)));

    ScriptStack missingContextStack = new ScriptStack();
    missingContextStack.push(ScriptNum.encodeScriptNum(10, ScriptNum.MAX_SCRIPTNUM_SIZE_LOCKTIME));
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKSEQUENCEVERIFY)},
                missingContextStack,
                null,
                ScriptInterpreter.EvalOptions.withFlags(
                    ScriptVerifyFlags.SCRIPT_VERIFY_CHECKSEQUENCEVERIFY)));
  }

  @Test
  void pushOpcodesAndSmallNumbers() {
    ScriptStack stack = new ScriptStack();
    byte[] script =
        new byte[] {
          op(OpCodes.OP_0),
          op(OpCodes.OP_1),
          op(OpCodes.OP_16),
          op(OpCodes.OP_1NEGATE),
          0x04,
          0x01,
          0x02,
          0x03,
          0x04
        };
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(5, stack.size());
    assertArrayEquals(new byte[0], stack.snapshot()[0]);
    assertArrayEquals(new byte[] {0x01}, stack.snapshot()[1]);
    assertArrayEquals(new byte[] {0x10}, stack.snapshot()[2]);
    assertArrayEquals(new byte[] {(byte) 0x81}, stack.snapshot()[3]);
    assertArrayEquals(Hex.decode("01020304"), stack.snapshot()[4]);
  }

  @Test
  void pushDataOpcodes() {
    ScriptStack stack = new ScriptStack();
    byte[] payload = Hex.decode("deadbeef");
    byte[] script =
        concat(
            new byte[] {op(OpCodes.OP_PUSHDATA1), 0x04},
            payload,
            new byte[] {op(OpCodes.OP_PUSHDATA2), 0x04, 0x00},
            payload,
            new byte[] {op(OpCodes.OP_PUSHDATA4), 0x04, 0x00, 0x00, 0x00},
            payload);
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(3, stack.size());
    for (byte[] item : stack.snapshot()) {
      assertArrayEquals(payload, item);
    }
  }

  @Test
  void opEqualVerifyAndDrop() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x01});
    stack.push(new byte[] {0x01});
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_EQUAL), op(OpCodes.OP_VERIFY)},
        stack,
        ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(stack.isEmpty());

    stack.push(new byte[] {0x00});
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_VERIFY)}, stack, ScriptInterpreter.EvalOptions.withFlags(0)));

    stack.push(new byte[] {0x01});
    ScriptInterpreter.evaluateScript(
        new byte[] {op(OpCodes.OP_DROP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(stack.isEmpty());
  }

  @Test
  void stackPopUnderflowThrows() {
    assertThrows(ScriptError.class, () -> new ScriptStack().pop());
  }

  @Test
  void stackPeekUnderflowThrows() {
    assertThrows(ScriptError.class, () -> new ScriptStack().peek());
  }

  @Test
  void evaluateUnderflowThrows() {
    ScriptStack stack = new ScriptStack();
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_DUP)}, stack, ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void unsupportedOpcodeThrows() {
    ScriptStack stack = new ScriptStack();
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {(byte) 0xff}, stack, ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void nullOptionsUsesDefaults() {
    ScriptStack stack = new ScriptStack();
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {op(OpCodes.OP_CHECKLOCKTIMEVERIFY)}, stack, null));
  }

  @Test
  void encodeOpNRejectsOutOfRange() {
    assertThrows(ScriptError.class, () -> ScriptInterpreter.encodeOpN(17));
  }

  @Test
  void terminalSuccessRelaxedAllowsJunkBelowTrueTop() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x00});
    stack.push(new byte[] {0x01});
    assertTrue(ScriptInterpreter.terminalSuccessRelaxed(stack));
    assertFalse(ScriptInterpreter.terminalSuccessStrict(stack));
  }

  @Test
  void terminalSuccessRelaxedRejectsEmptyOrFalseTop() {
    assertFalse(ScriptInterpreter.terminalSuccessRelaxed(new ScriptStack()));
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[] {0x00});
    assertFalse(ScriptInterpreter.terminalSuccessRelaxed(stack));
  }

  @Test
  void castToBoolHandlesNegativeZero() {
    assertFalse(ScriptInterpreter.castToBool(new byte[] {(byte) 0x80}));
    assertTrue(ScriptInterpreter.castToBool(new byte[] {0x01}));
    assertFalse(ScriptInterpreter.castToBool(new byte[0]));
  }

  @Test
  void castToBoolAcceptsLeadingNegativeZeroByteBeforeTrailingZeros() {
    // testnet4 @46599 tapscript terminal stack item 0x809e000000000000
    assertTrue(
        ScriptInterpreter.castToBool(
            new byte[] {(byte) 0x80, (byte) 0x9e, 0, 0, 0, 0, 0, 0}));
    assertTrue(ScriptInterpreter.castToBool(new byte[] {(byte) 0x80, 0x01}));
  }

  @Test
  void evalOptionsDefaults() {
    assertEquals(
        ScriptVerifyFlags.SCRIPT_VERIFY_DEFAULT,
        ScriptInterpreter.EvalOptions.defaults().verifyFlags());
  }

  @Test
  void scriptPushErrors() {
    assertThrows(ScriptError.class, () -> ScriptPush.readPush(new byte[] {(byte) 0xff}, 0));
    assertThrows(ScriptError.class, () -> ScriptPush.readPush(new byte[] {0x05, 0x01}, 0));
  }

  @Test
  void legacyIfElseSkipsInactiveBranch() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    byte[] script =
        new byte[] {
          (byte) OpCodes.OP_IF,
          (byte) OpCodes.OP_1,
          (byte) OpCodes.OP_ELSE,
          (byte) OpCodes.OP_0,
          (byte) OpCodes.OP_ENDIF
        };
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(ScriptInterpreter.terminalSuccessStrict(stack));
  }

  @Test
  void legacyNotifInvertsBranch() {
    ScriptStack stack = new ScriptStack();
    stack.push(Hex.decode("01"));
    byte[] script =
        new byte[] {
          (byte) OpCodes.OP_NOTIF,
          (byte) OpCodes.OP_0,
          (byte) OpCodes.OP_ELSE,
          (byte) OpCodes.OP_1,
          (byte) OpCodes.OP_ENDIF
        };
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertTrue(ScriptInterpreter.terminalSuccessStrict(stack));
  }

  @Test
  void legacyRejectsUnbalancedConditional() {
    ScriptStack stack = new ScriptStack();
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {(byte) OpCodes.OP_ENDIF},
                stack,
                ScriptInterpreter.EvalOptions.withFlags(0)));
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {(byte) OpCodes.OP_ELSE},
                stack,
                ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void legacyIfStackEmptyThrows() {
    ScriptStack stack = new ScriptStack();
    assertThrows(
        ScriptError.class,
        () ->
            ScriptInterpreter.evaluateScript(
                new byte[] {(byte) OpCodes.OP_IF},
                stack,
                ScriptInterpreter.EvalOptions.withFlags(0)));
  }

  @Test
  void legacyInactiveBranchSkipsPushData() {
    ScriptStack stack = new ScriptStack();
    stack.push(new byte[0]);
    byte[] script =
        new byte[] {
          (byte) OpCodes.OP_IF,
          (byte) OpCodes.OP_1,
          (byte) OpCodes.OP_ELSE,
          0x04,
          0x01,
          0x02,
          0x03,
          0x04,
          (byte) OpCodes.OP_ENDIF
        };
    ScriptInterpreter.evaluateScript(script, stack, ScriptInterpreter.EvalOptions.withFlags(0));
    assertEquals(1, stack.size());
    assertArrayEquals(Hex.decode("01020304"), stack.peek());
  }

  private static byte op(int opcode) {
    return (byte) opcode;
  }

  private static byte[] concat(byte[]... parts) {
    int length = 0;
    for (byte[] part : parts) {
      length += part.length;
    }
    byte[] out = new byte[length];
    int offset = 0;
    for (byte[] part : parts) {
      System.arraycopy(part, 0, out, offset, part.length);
      offset += part.length;
    }
    return out;
  }
}
