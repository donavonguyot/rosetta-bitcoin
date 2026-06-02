package com.jbitnode.db;

/** Height/hash pair for the authoritative active chainstate tip. */
public record ChainstateTip(int height, String hash) {}
