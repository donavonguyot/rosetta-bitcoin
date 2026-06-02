package com.jbitnode.wire;

/** Parsed 24-byte Bitcoin P2P message header. */
public record MessageHeader(byte[] magic, String command, int length, byte[] checksum) {}
