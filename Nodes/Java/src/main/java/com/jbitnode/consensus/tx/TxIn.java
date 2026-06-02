package com.jbitnode.consensus.tx;

/** Transaction input (outpoint, scriptSig, sequence). */
public record TxIn(OutPoint previousOutput, byte[] scriptSig, long sequence) {}
