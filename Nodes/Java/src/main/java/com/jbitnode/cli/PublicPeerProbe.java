package com.jbitnode.cli;

/** CLI entry point for the bounded outbound public-peer validator probe. */
public final class PublicPeerProbe {

  private PublicPeerProbe() {}

  public static void main(String[] args) {
    System.exit(PublicPeerProbeService.run(System.out, System.getenv()));
  }
}
