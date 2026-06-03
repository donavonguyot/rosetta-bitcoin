package com.jbitnode.sync;

import java.io.IOException;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Background, in-order block prefetch that overlaps peer download (network I/O) with block
 * connection (CPU-bound script verification, which dominates connect time).
 *
 * <p>The worker thread performs only the supplied fetch and never touches the operational store,
 * chainstate, or block storage. All of those writes stay on the consumer (connect) thread, so the
 * two threads share no mutable state beyond the bounded result queue. The queue capacity bounds how
 * far ahead the worker may run (backpressure), so memory stays bounded regardless of block size.
 */
final class BlockPrefetcher implements AutoCloseable {

  /** A block to fetch: its height and the internal (little-endian) block hash for the inv vector. */
  record Plan(int height, byte[] blockHashInternal) {}

  /** A fetched block in plan order. {@code payload} is null on notfound/mismatch/timeout. */
  record Fetched(int height, byte[] payload, IOException error) {}

  /** Tracker-free block fetch (e.g. {@code PeerConnection#requestBlock}). */
  @FunctionalInterface
  interface Fetch {
    byte[] fetch(byte[] blockHashInternal) throws IOException;
  }

  private final BlockingQueue<Fetched> results;
  private final Thread worker;
  private final AtomicBoolean cancelled = new AtomicBoolean(false);

  BlockPrefetcher(Fetch fetch, List<Plan> plan, int depth) {
    this.results = new ArrayBlockingQueue<>(Math.max(1, depth));
    this.worker = new Thread(() -> run(fetch, plan), "jbitnode-block-prefetch");
    this.worker.setDaemon(true);
    this.worker.start();
  }

  private void run(Fetch fetch, List<Plan> plan) {
    for (Plan entry : plan) {
      if (cancelled.get()) {
        return;
      }
      Fetched fetched;
      try {
        byte[] payload = fetch.fetch(entry.blockHashInternal());
        fetched = new Fetched(entry.height(), payload, null);
      } catch (IOException error) {
        fetched = new Fetched(entry.height(), null, error);
      }
      if (!enqueue(fetched)) {
        return;
      }
      // Stop after surfacing a fetch error or an unavailable (null) block; the consumer turns
      // either into a sync blocker, after which any further prefetch would be discarded anyway.
      if (fetched.error() != null || fetched.payload() == null) {
        return;
      }
    }
  }

  private boolean enqueue(Fetched fetched) {
    while (!cancelled.get()) {
      try {
        if (results.offer(fetched, 200, TimeUnit.MILLISECONDS)) {
          return true;
        }
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
        return false;
      }
    }
    return false;
  }

  /**
   * Returns the next block in plan order, or null if the wait timed out. Re-throws a fetch error
   * raised by the worker so the sync loop surfaces it exactly as a synchronous download would.
   */
  Fetched take(long timeoutMs) throws IOException, InterruptedException {
    Fetched fetched = results.poll(timeoutMs, TimeUnit.MILLISECONDS);
    if (fetched != null && fetched.error() != null) {
      throw fetched.error();
    }
    return fetched;
  }

  @Override
  public void close() {
    cancelled.set(true);
    worker.interrupt();
  }
}
