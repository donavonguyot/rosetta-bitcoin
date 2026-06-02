package com.jbitnode.consensus.script;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.jbitnode.config.ScriptVerifySettings;
import com.jbitnode.consensus.connect.ValidationBlocker;
import com.jbitnode.consensus.script.ScriptVerifyRunner.InputVerifyTask;
import com.jbitnode.consensus.script.ScriptVerifyRunner.VerifyContext;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.testutil.ScriptTestHelpers;
import com.jbitnode.util.Hex;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class ScriptVerifyRunnerTest {

  @Test
  void sequentialAndParallelAgreeOnValidMultiInputSpend() throws Exception {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    VerifyContext context = new VerifyContext(2, "bb".repeat(32), "aa".repeat(32));
    AtomicLong sequentialNanos = new AtomicLong();
    assertDoesNotThrow(
        () ->
            ScriptVerifyRunner.verifyInputs(
                fixture.transaction(),
                fixture.spentPrevouts(),
                fixture.tasks(),
                context,
                ScriptVerifySettings.sequentialOnly(),
                sequentialNanos::addAndGet));

    AtomicLong parallelNanos = new AtomicLong();
    assertDoesNotThrow(
        () ->
            ScriptVerifyRunner.verifyInputs(
                fixture.transaction(),
                fixture.spentPrevouts(),
                fixture.tasks(),
                context,
                new ScriptVerifySettings(true, 4, 2),
                parallelNanos::addAndGet));
    assertTrue(sequentialNanos.get() > 0);
    assertTrue(parallelNanos.get() > 0);
  }

  @Test
  void parallelReportsLowestInputIndexOnFailure() {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    List<InputVerifyTask> tasks =
        List.of(
            fixture.tasks().getFirst(),
            new InputVerifyTask(
                1,
                Hex.decode("5120" + "22".repeat(32)),
                20_000,
                "5120" + "22".repeat(32)));
    ValidationBlocker blocker =
        assertThrows(
            ValidationBlocker.class,
            () ->
                ScriptVerifyRunner.verifyInputs(
                    fixture.transaction(),
                    fixture.spentPrevouts(),
                    tasks,
                    new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
                    new ScriptVerifySettings(true, 4, 2),
                    ignored -> {}));
    assertEquals(1, blocker.inputIndex());
    assertEquals("script_verification_failed", blocker.missingRule());
  }

  @Test
  void blockParallelReportsLowestTransactionThenInputOnFailure() throws Exception {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    try (ScriptVerifyRunner runner =
        new ScriptVerifyRunner(new ScriptVerifySettings(true, 2, 1))) {
      SighashCache sighashCache =
          runner.sighashCacheForTransaction(
              fixture.transaction(), fixture.spentPrevouts(), (stage, nanos) -> {});
      InputVerifyTask invalidInputZero =
          new InputVerifyTask(0, Hex.decode("5120" + "11".repeat(32)), 30_000, "5120" + "11".repeat(32));
      InputVerifyTask invalidInputOne =
          new InputVerifyTask(1, Hex.decode("5120" + "22".repeat(32)), 20_000, "5120" + "22".repeat(32));
      VerifyContext laterContext = new VerifyContext(2, "bb".repeat(32), "cc".repeat(32));
      VerifyContext earlierContext = new VerifyContext(2, "bb".repeat(32), "dd".repeat(32));

      ValidationBlocker blocker =
          assertThrows(
              ValidationBlocker.class,
              () ->
                  runner.verifyBlockInputs(
                      List.of(
                          new ScriptVerifyRunner.BlockInputVerifyJob(
                              5,
                              fixture.transaction(),
                              fixture.spentPrevouts(),
                              invalidInputZero,
                              laterContext,
                              sighashCache),
                          new ScriptVerifyRunner.BlockInputVerifyJob(
                              3,
                              fixture.transaction(),
                              fixture.spentPrevouts(),
                              invalidInputOne,
                              earlierContext,
                              sighashCache)),
                      (stage, nanos) -> {}));
      assertEquals(1, blocker.inputIndex());
      assertEquals("dd".repeat(32), blocker.txidHex());
    }
  }

  @Test
  void sequentialPathUsedForSingleInputEvenWhenParallelEnabled() {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    List<InputVerifyTask> singleTask = List.of(fixture.tasks().getFirst());
    AtomicLong elapsed = new AtomicLong();
    assertDoesNotThrow(
        () ->
            ScriptVerifyRunner.verifyInputs(
                fixture.transaction(),
                fixture.spentPrevouts(),
                singleTask,
                new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
                ScriptVerifySettings.defaults(),
                elapsed::addAndGet));
    assertTrue(elapsed.get() > 0);
  }

  @Test
  void belowThresholdPathDoesNotCreateExecutor() throws Exception {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    try (ScriptVerifyRunner runner =
        new ScriptVerifyRunner(
            new ScriptVerifySettings(true, 4, 3),
            () -> {
              throw new AssertionError("executor should not be created");
            })) {
      AtomicLong elapsed = new AtomicLong();
      assertDoesNotThrow(
          () ->
              runner.verifyInputs(
                  fixture.transaction(),
                  fixture.spentPrevouts(),
                  fixture.tasks(),
                  new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
                  elapsed::addAndGet));
      assertTrue(elapsed.get() > 0);
    }
  }

  @Test
  void parallelPathReusesExecutorAndCloseShutsItDown() throws Exception {
    MultiInputFixture fixture = buildValidMultiInputFixture();
    AtomicInteger created = new AtomicInteger();
    List<ExecutorService> executors = new ArrayList<>();
    ScriptVerifyRunner runner =
        new ScriptVerifyRunner(
            new ScriptVerifySettings(true, 2, 2),
            () -> {
              created.incrementAndGet();
              ExecutorService executor = Executors.newFixedThreadPool(2);
              executors.add(executor);
              return executor;
            });
    AtomicLong elapsed = new AtomicLong();
    runner.verifyInputs(
        fixture.transaction(),
        fixture.spentPrevouts(),
        fixture.tasks(),
        new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
        elapsed::addAndGet);
    runner.verifyInputs(
        fixture.transaction(),
        fixture.spentPrevouts(),
        fixture.tasks(),
        new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
        elapsed::addAndGet);
    runner.close();

    assertEquals(1, created.get());
    assertEquals(1, executors.size());
    assertTrue(executors.getFirst().isShutdown());
    assertTrue(elapsed.get() > 0);
    assertThrows(
        IllegalStateException.class,
        () ->
            runner.verifyInputs(
                fixture.transaction(),
                fixture.spentPrevouts(),
                fixture.tasks(),
                new VerifyContext(2, "bb".repeat(32), "aa".repeat(32)),
                ignored -> {}));
  }

  @Test
  void emptyTaskListIsNoOp() {
    assertDoesNotThrow(
        () ->
            ScriptVerifyRunner.verifyInputs(
                new Transaction(1, List.of(), List.of(), 0, List.of()),
                List.of(),
                List.of(),
                new VerifyContext(1, "aa".repeat(32), "bb".repeat(32)),
                ScriptVerifySettings.defaults(),
                ignored -> {}));
  }

  private record MultiInputFixture(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks) {}

  private static MultiInputFixture buildValidMultiInputFixture() {
    BigInteger privateKey = BigInteger.ONE;
    byte[] pubkey = Secp256k1.testPubkeySec1(privateKey);
    byte[] fundingScript =
        ScriptTestHelpers.p2pkhScriptPubKey(
            com.jbitnode.consensus.script.ScriptHash.hash160(pubkey));
    byte[] fundingTxid1 = Hex.decode("cc".repeat(32));
    byte[] fundingTxid2 = Hex.decode("dd".repeat(32));

    Transaction transaction =
        signedTwoInputP2pkhSpend(
            privateKey, pubkey, fundingScript, fundingTxid1, fundingTxid2);

    List<ScriptVerify.SpentPrevout> spentPrevouts =
        List.of(
            new ScriptVerify.SpentPrevout(30_000, fundingScript),
            new ScriptVerify.SpentPrevout(20_000, fundingScript));
    List<InputVerifyTask> tasks =
        List.of(
            new InputVerifyTask(0, fundingScript, 30_000, Hex.encode(fundingScript)),
            new InputVerifyTask(1, fundingScript, 20_000, Hex.encode(fundingScript)));
    return new MultiInputFixture(transaction, spentPrevouts, tasks);
  }

  private static Transaction signedTwoInputP2pkhSpend(
      BigInteger privateKey,
      byte[] pubkey,
      byte[] scriptPubKey,
      byte[] fundingTxid1,
      byte[] fundingTxid2) {
    Transaction unsigned =
        new Transaction(
            1,
            List.of(
                new TxIn(new OutPoint(fundingTxid1, 0), new byte[0], 0xffff_ffffL),
                new TxIn(new OutPoint(fundingTxid2, 0), new byte[0], 0xffff_ffffL)),
            List.of(new TxOut(48_000, new byte[] {0x51})),
            0,
            List.of());
    byte[] sighash0 = LegacySighash.legacySighash(unsigned, 0, scriptPubKey, 1);
    byte[] sighash1 = LegacySighash.legacySighash(unsigned, 1, scriptPubKey, 1);
    byte[] signature0 =
        concat(Secp256k1.signDer(privateKey, sighash0), new byte[] {0x01});
    byte[] signature1 =
        concat(Secp256k1.signDer(privateKey, sighash1), new byte[] {0x01});
    byte[] scriptSig0 =
        concat(ScriptTestHelpers.pushData(signature0), ScriptTestHelpers.pushData(pubkey));
    byte[] scriptSig1 =
        concat(ScriptTestHelpers.pushData(signature1), ScriptTestHelpers.pushData(pubkey));
    return new Transaction(
        unsigned.version(),
        List.of(
            new TxIn(unsigned.inputs().get(0).previousOutput(), scriptSig0, 0xffff_ffffL),
            new TxIn(unsigned.inputs().get(1).previousOutput(), scriptSig1, 0xffff_ffffL)),
        unsigned.outputs(),
        unsigned.lockTime(),
        List.of());
  }

  private static byte[] concat(byte[] first, byte[] second) {
    byte[] out = new byte[first.length + second.length];
    System.arraycopy(first, 0, out, 0, first.length);
    System.arraycopy(second, 0, out, first.length, second.length);
    return out;
  }
}
