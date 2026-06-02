package com.jbitnode.messages;

/** Parsed version message payload. */
public record VersionMessage(
    int version,
    long services,
    long timestamp,
    NetworkAddress addrRecv,
    NetworkAddress addrFrom,
    long nonce,
    String userAgent,
    int startHeight,
    boolean relay) {}
