package com.jbitnode.consensus.script;

import com.jbitnode.config.ScriptVerifySettings;
import com.jbitnode.consensus.connect.ValidationBlocker;
import com.jbitnode.consensus.secp256k1.Secp256k1;
import com.jbitnode.consensus.tx.Transaction;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.BiConsumer;
import java.util.function.LongConsumer;
import java.util.function.Supplier;

/** Runs script verification sequentially or in parallel across transaction inputs. */
public final class ScriptVerifyRunner implements AutoCloseable {

  private final ScriptVerifySettings settings;
  private final Supplier<ExecutorService> executorFactory;
  private final Secp256k1.VerificationCache secp256k1Cache = new Secp256k1.VerificationCache();
  private ExecutorService executor;
  private boolean closed;

  public ScriptVerifyRunner(ScriptVerifySettings settings) {
    this(settings, () -> Executors.newFixedThreadPool(settings.maxThreads()));
  }

  ScriptVerifyRunner(ScriptVerifySettings settings, Supplier<ExecutorService> executorFactory) {
    this.settings = settings;
    this.executorFactory = executorFactory;
  }

  public record InputVerifyTask(
      int inputIndex, byte[] scriptPubKey, long valueSats, String scriptPubKeyHex) {}

  public record VerifyContext(int height, String blockHashHex, String txidHex) {}

  public record BlockInputVerifyJob(
      int transactionIndex,
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      InputVerifyTask task,
      VerifyContext context,
      SighashCache sighashCache) {}

  public static void verifyInputs(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks,
      VerifyContext context,
      ScriptVerifySettings settings,
      LongConsumer timingSinkNanos)
      throws ValidationBlocker {
    try (ScriptVerifyRunner runner = new ScriptVerifyRunner(settings)) {
      runner.verifyInputs(transaction, spentPrevouts, tasks, context, timingSinkNanos);
    }
  }

  @FunctionalInterface
  public interface ScriptTimingSink extends BiConsumer<String, Long> {}

  public void verifyInputs(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks,
      VerifyContext context,
      LongConsumer timingSinkNanos)
      throws ValidationBlocker {
    verifyInputs(
        transaction,
        spentPrevouts,
        tasks,
        context,
        (stage, elapsedNanos) -> {
          if ("script_verify".equals(stage)) {
            timingSinkNanos.accept(elapsedNanos);
          }
        });
  }

  public void verifyInputs(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks,
      VerifyContext context,
      ScriptTimingSink timingSink)
      throws ValidationBlocker {
    if (closed) {
      throw new IllegalStateException("script verify runner is closed");
    }
    if (tasks.isEmpty()) {
      return;
    }
    SighashCache sighashCache = sighashCacheForTransaction(transaction, spentPrevouts, timingSink);
    if (!settings.parallelEnabled() || tasks.size() < settings.minInputs()) {
      verifySequential(transaction, spentPrevouts, tasks, context, sighashCache, timingSink);
      return;
    }
    verifyParallel(transaction, spentPrevouts, tasks, context, sighashCache, timingSink);
  }

  public SighashCache sighashCacheForTransaction(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      ScriptTimingSink timingSink) {
    long cacheStarted = System.nanoTime();
    try {
      return SighashCache.forTransaction(transaction, spentPrevouts, secp256k1Cache);
    } finally {
      timingSink.accept("script_sighash_cache_build", System.nanoTime() - cacheStarted);
    }
  }

  public void verifyBlockInputs(List<BlockInputVerifyJob> jobs, ScriptTimingSink timingSink)
      throws ValidationBlocker {
    if (closed) {
      throw new IllegalStateException("script verify runner is closed");
    }
    if (jobs.isEmpty()) {
      return;
    }
    if (!settings.parallelEnabled() || jobs.size() < settings.minInputs()) {
      for (BlockInputVerifyJob job : jobs) {
        long started = System.nanoTime();
        try {
          ScriptVerifyProfiler.withRecorderThrowing(
              timingSink::accept,
              () ->
                  verifyOneInput(
                      job.transaction(),
                      job.spentPrevouts(),
                      job.task(),
                      job.context(),
                      job.sighashCache()));
        } finally {
          timingSink.accept("script_verify", System.nanoTime() - started);
        }
      }
      return;
    }
    verifyBlockInputsParallel(jobs, timingSink);
  }

  private static void verifySequential(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks,
      VerifyContext context,
      SighashCache sighashCache,
      ScriptTimingSink timingSink)
      throws ValidationBlocker {
    for (InputVerifyTask task : tasks) {
      long started = System.nanoTime();
      try {
        ScriptVerifyProfiler.withRecorderThrowing(
            timingSink::accept,
            () -> verifyOneInput(transaction, spentPrevouts, task, context, sighashCache));
      } finally {
        timingSink.accept("script_verify", System.nanoTime() - started);
      }
    }
  }

  private void verifyParallel(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      List<InputVerifyTask> tasks,
      VerifyContext context,
      SighashCache sighashCache,
      ScriptTimingSink timingSink)
      throws ValidationBlocker {
    ExecutorService executor = executor();
    Map<String, AtomicLong> stageNanos = new ConcurrentHashMap<>();
    List<Callable<ValidationBlocker>> jobs = new ArrayList<>(tasks.size());
    for (InputVerifyTask task : tasks) {
      jobs.add(
          () -> {
            long started = System.nanoTime();
            try {
              ScriptVerifyProfiler.withRecorderThrowing(
                  (stage, elapsedNanos) ->
                      stageNanos.computeIfAbsent(stage, ignored -> new AtomicLong()).addAndGet(elapsedNanos),
                  () -> verifyOneInput(transaction, spentPrevouts, task, context, sighashCache));
              return null;
            } catch (ValidationBlocker blocker) {
              return blocker;
            } finally {
              stageNanos
                  .computeIfAbsent("script_verify", ignored -> new AtomicLong())
                  .addAndGet(System.nanoTime() - started);
            }
          });
    }
    try {
      long waitStarted = System.nanoTime();
      List<ValidationBlocker> failures = new ArrayList<>();
      for (Future<ValidationBlocker> future : executor.invokeAll(jobs)) {
        ValidationBlocker failure = getFailure(future);
        if (failure != null) {
          failures.add(failure);
        }
      }
      stageNanos
          .computeIfAbsent("script_runner_wait", ignored -> new AtomicLong())
          .addAndGet(System.nanoTime() - waitStarted);
      for (Map.Entry<String, AtomicLong> entry : stageNanos.entrySet()) {
        timingSink.accept(entry.getKey(), entry.getValue().get());
      }
      if (!failures.isEmpty()) {
        failures.sort(Comparator.comparingInt(ValidationBlocker::inputIndex));
        throw failures.getFirst();
      }
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("parallel script verify interrupted", error);
    }
  }

  private void verifyBlockInputsParallel(
      List<BlockInputVerifyJob> blockJobs, ScriptTimingSink timingSink)
      throws ValidationBlocker {
    ExecutorService executor = executor();
    Map<String, AtomicLong> stageNanos = new ConcurrentHashMap<>();
    List<Callable<JobFailure>> jobs = new ArrayList<>(blockJobs.size());
    for (BlockInputVerifyJob job : blockJobs) {
      jobs.add(
          () -> {
            long started = System.nanoTime();
            try {
              ScriptVerifyProfiler.withRecorderThrowing(
                  (stage, elapsedNanos) ->
                      stageNanos.computeIfAbsent(stage, ignored -> new AtomicLong()).addAndGet(elapsedNanos),
                  () ->
                      verifyOneInput(
                          job.transaction(),
                          job.spentPrevouts(),
                          job.task(),
                          job.context(),
                          job.sighashCache()));
              return null;
            } catch (ValidationBlocker blocker) {
              return new JobFailure(job.transactionIndex(), blocker);
            } finally {
              stageNanos
                  .computeIfAbsent("script_verify", ignored -> new AtomicLong())
                  .addAndGet(System.nanoTime() - started);
            }
          });
    }
    try {
      long waitStarted = System.nanoTime();
      List<JobFailure> failures = new ArrayList<>();
      for (Future<JobFailure> future : executor.invokeAll(jobs)) {
        JobFailure failure = getJobFailure(future);
        if (failure != null) {
          failures.add(failure);
        }
      }
      stageNanos
          .computeIfAbsent("script_runner_wait", ignored -> new AtomicLong())
          .addAndGet(System.nanoTime() - waitStarted);
      for (Map.Entry<String, AtomicLong> entry : stageNanos.entrySet()) {
        timingSink.accept(entry.getKey(), entry.getValue().get());
      }
      if (!failures.isEmpty()) {
        failures.sort(
            Comparator.comparingInt(JobFailure::transactionIndex)
                .thenComparingInt(failure -> failure.blocker().inputIndex()));
        throw failures.getFirst().blocker();
      }
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("parallel script verify interrupted", error);
    }
  }

  private ExecutorService executor() {
    if (executor == null) {
      executor = executorFactory.get();
    }
    return executor;
  }

  private static ValidationBlocker getFailure(Future<ValidationBlocker> future) {
    try {
      return future.get();
    } catch (ExecutionException error) {
      Throwable cause = error.getCause();
      if (cause instanceof ValidationBlocker blocker) {
        return blocker;
      } else if (cause instanceof RuntimeException runtime) {
        throw runtime;
      } else if (cause instanceof Error err) {
        throw err;
      }
      throw new IllegalStateException("parallel script verify failed", cause);
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("parallel script verify interrupted", error);
    }
  }

  private record JobFailure(int transactionIndex, ValidationBlocker blocker) {}

  private static JobFailure getJobFailure(Future<JobFailure> future) {
    try {
      return future.get();
    } catch (ExecutionException error) {
      Throwable cause = error.getCause();
      if (cause instanceof RuntimeException runtime) {
        throw runtime;
      } else if (cause instanceof Error err) {
        throw err;
      }
      throw new IllegalStateException("parallel script verify failed", cause);
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("parallel script verify interrupted", error);
    }
  }

  @Override
  public void close() {
    closed = true;
    if (executor != null) {
      executor.shutdownNow();
      executor = null;
    }
  }

  private static void verifyOneInput(
      Transaction transaction,
      List<ScriptVerify.SpentPrevout> spentPrevouts,
      InputVerifyTask task,
      VerifyContext context,
      SighashCache sighashCache)
      throws ValidationBlocker {
    try {
      ScriptVerify.verifyTransactionInput(
          transaction,
          task.inputIndex(),
          new ScriptVerify.VerifyInputOptions(
              task.scriptPubKey(), task.valueSats(), spentPrevouts, sighashCache));
    } catch (UnsupportedScriptRule error) {
      throw new ValidationBlocker(
          context.height(),
          context.blockHashHex(),
          context.txidHex(),
          task.inputIndex(),
          task.scriptPubKeyHex(),
          error.getMessage(),
          error.getRule());
    } catch (ScriptVerifyError error) {
      if (error.getMessage().contains("unsupported scriptPubKey template")) {
        String template = ScriptVerify.describeScriptPubKey(task.scriptPubKey());
        throw ValidationBlocker.fromUnsupportedTemplate(
            context.height(),
            context.blockHashHex(),
            context.txidHex(),
            task.inputIndex(),
            task.scriptPubKey(),
            template);
      }
      throw new ValidationBlocker(
          context.height(),
          context.blockHashHex(),
          context.txidHex(),
          task.inputIndex(),
          task.scriptPubKeyHex(),
          error.getMessage(),
          "script_verification_failed");
    }
  }
}
