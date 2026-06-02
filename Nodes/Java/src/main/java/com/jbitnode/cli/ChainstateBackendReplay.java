package com.jbitnode.cli;

/** CLI entry for offline chainstate backend replay benchmarks. */
public final class ChainstateBackendReplay {

  private ChainstateBackendReplay() {}

  public static void main(String[] args) {
    System.exit(ChainstateBackendReplayService.run(System.out, System.getenv()));
  }
}
