package com.jbitnode.consensus.tx;

/** Transaction output (value in satoshis, scriptPubKey). */
public record TxOut(long value, byte[] scriptPubKey) {}
