package com.jbitnode.consensus.block;

import com.jbitnode.consensus.BlockHeader;
import com.jbitnode.consensus.tx.Transaction;
import java.util.List;

/** Block header plus parsed transactions (wire block payload without magic/size). */
public record Block(BlockHeader header, List<Transaction> transactions) {}
