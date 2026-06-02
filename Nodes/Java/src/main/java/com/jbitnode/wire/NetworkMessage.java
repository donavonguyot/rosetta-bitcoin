package com.jbitnode.wire;

/** A decoded P2P network message (command + payload). */
public record NetworkMessage(String command, byte[] payload) {}
