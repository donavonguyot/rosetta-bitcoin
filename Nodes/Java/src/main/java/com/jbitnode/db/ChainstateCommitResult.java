package com.jbitnode.db;

/** Result of committing one block into the active chainstate. */
public record ChainstateCommitResult(
    ChainstateTip tip, int utxosCreated, int utxosSpent, ChainstateMetadata metadata) {}
