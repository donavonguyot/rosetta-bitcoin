package com.jbitnode.chain;

/** Bitcoin chain parameters for P2P and consensus validation. */
public record ChainParams(
    String name,
    byte[] magic,
    int defaultPort,
    String genesisHash,
    int protocolVersion,
    String userAgent) {}
