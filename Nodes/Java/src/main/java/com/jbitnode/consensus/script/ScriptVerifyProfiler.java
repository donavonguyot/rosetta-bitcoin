package com.jbitnode.consensus.script;

import com.jbitnode.consensus.connect.ValidationBlocker;

/** Thread-local timing hooks for script verification sub-stages. */
public final class ScriptVerifyProfiler {

  @FunctionalInterface
  public interface Recorder {
    void record(String stage, long elapsedNanos);
  }

  @FunctionalInterface
  public interface ThrowingSupplier<T> {
    T get();
  }

  @FunctionalInterface
  public interface ThrowingRunnable {
    void run() throws ValidationBlocker;
  }

  private static final ThreadLocal<Recorder> CURRENT = new ThreadLocal<>();

  private ScriptVerifyProfiler() {}

  public static void withRecorder(Recorder recorder, Runnable runnable) {
    Recorder previous = CURRENT.get();
    CURRENT.set(recorder);
    try {
      runnable.run();
    } finally {
      if (previous == null) {
        CURRENT.remove();
      } else {
        CURRENT.set(previous);
      }
    }
  }

  public static void withRecorderThrowing(Recorder recorder, ThrowingRunnable runnable)
      throws ValidationBlocker {
    Recorder previous = CURRENT.get();
    CURRENT.set(recorder);
    try {
      runnable.run();
    } finally {
      if (previous == null) {
        CURRENT.remove();
      } else {
        CURRENT.set(previous);
      }
    }
  }

  public static <T> T measure(String stage, ThrowingSupplier<T> supplier) {
    Recorder recorder = CURRENT.get();
    if (recorder == null) {
      return supplier.get();
    }
    long started = System.nanoTime();
    try {
      return supplier.get();
    } finally {
      recorder.record(stage, System.nanoTime() - started);
    }
  }

  public static void measure(String stage, Runnable runnable) {
    Recorder recorder = CURRENT.get();
    if (recorder == null) {
      runnable.run();
      return;
    }
    long started = System.nanoTime();
    try {
      runnable.run();
    } finally {
      recorder.record(stage, System.nanoTime() - started);
    }
  }
}
