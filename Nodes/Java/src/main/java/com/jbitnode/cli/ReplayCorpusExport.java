package com.jbitnode.cli;

/** CLI entry point for exporting a portable replay corpus from stored blocks. */
public final class ReplayCorpusExport {

  private ReplayCorpusExport() {}

  public static void main(String[] args) {
    System.exit(ReplayCorpusExportService.run(System.out, System.getenv()));
  }
}
