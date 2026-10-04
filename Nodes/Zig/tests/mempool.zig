const std = @import("std");
const core = @import("zigbitnode");

const script_true = [_]u8{0x51};
const script_false = [_]u8{0x00};

fn rawTx(
    allocator: std.mem.Allocator,
    version: i32,
    prev: [32]u8,
    vout: u32,
    sequence: u32,
    script_sig: []const u8,
    value: i64,
    script_pubkey: []const u8,
    lock_time: u32,
) ![]u8 {
    const sig = try allocator.dupe(u8, script_sig);
    const spk = try allocator.dupe(u8, script_pubkey);
    const inputs = try allocator.alloc(core.tx.TxIn, 1);
    inputs[0] = .{
        .previous_output = .{ .hash = prev, .index = vout },
        .script_sig = sig,
        .sequence = sequence,
    };
    const outputs = try allocator.alloc(core.tx.TxOut, 1);
    outputs[0] = .{ .value = value, .script_pubkey = spk };
    var transaction = core.tx.Transaction{
        .version = version,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = lock_time,
        .witness = &.{},
        .raw_no_witness = &.{},
    };
    transaction.raw_no_witness = try core.tx.serializeNoWitness(allocator, transaction);
    defer transaction.deinit(allocator);
    return try core.tx.serialize(allocator, transaction, false);
}

fn putCoin(store: *core.coins_view.MemoryStore, txid: [32]u8, vout: u32, value: u64, height: u32) !void {
    try store.putUtxo(.{ .txid = txid, .vout = vout }, .{
        .height = height,
        .vout = vout,
        .value_sats = value,
        .coinbase = false,
        .script_pubkey = &script_true,
    });
}

test "set hash folds in on accept and out on eviction" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const prev = [_]u8{1} ** 32;
    try putCoin(&backend, prev, 0, 50, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 0);
    defer pool.deinit();
    const zero = pool.setHashHex();
    const raw = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 40, &script_true, 0);
    defer allocator.free(raw);
    const verdict = try pool.apply(raw);
    try std.testing.expectEqual(core.mempool.Reason.accepted, verdict.reason);
    try std.testing.expect(!std.mem.eql(u8, &pool.setHashHex(), &zero));
    const parsed = try core.tx.deserialize(allocator, raw, 0);
    defer parsed.transaction.deinit(allocator);
    const txid = parsed.transaction.txid();
    try pool.onBlockConnected(&.{parsed.transaction}, &.{txid});
    try std.testing.expectEqualSlices(u8, &zero, &pool.setHashHex());
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

test "in-pool spend is accepted and a second spend is rejected" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const prev = [_]u8{2} ** 32;
    try putCoin(&backend, prev, 0, 50, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 0);
    defer pool.deinit();
    const parent = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 40, &script_true, 0);
    defer allocator.free(parent);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(parent)).reason);
    const parent_tx = try core.tx.deserialize(allocator, parent, 0);
    defer parent_tx.transaction.deinit(allocator);
    const child = try rawTx(allocator, 2, parent_tx.transaction.txid(), 0, 0xffffffff, &.{}, 30, &script_true, 0);
    defer allocator.free(child);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(child)).reason);
    const replacement = try rawTx(allocator, 2, parent_tx.transaction.txid(), 0, 0xffffffff, &.{}, 20, &script_true, 0);
    defer allocator.free(replacement);
    try std.testing.expectEqual(core.mempool.Reason.input_spent_in_pool, (try pool.apply(replacement)).reason);
}

test "on-chain double spend is rejected" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const prev = [_]u8{3} ** 32;
    try putCoin(&backend, prev, 0, 50, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 0);
    defer pool.deinit();
    try pool.coins.markChainSpend(.{ .txid = prev, .vout = 0 });
    const raw = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 40, &script_true, 0);
    defer allocator.free(raw);
    try std.testing.expectEqual(core.mempool.Reason.input_spent_on_chain, (try pool.apply(raw)).reason);
}

test "child before parent is accepted when the parent is applied first" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const prev = [_]u8{4} ** 32;
    try putCoin(&backend, prev, 0, 80, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 0);
    defer pool.deinit();
    const parent = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 70, &script_true, 0);
    defer allocator.free(parent);
    const parent_tx = try core.tx.deserialize(allocator, parent, 0);
    defer parent_tx.transaction.deinit(allocator);
    const child = try rawTx(allocator, 2, parent_tx.transaction.txid(), 0, 0xffffffff, &.{}, 60, &script_true, 0);
    defer allocator.free(child);
    try std.testing.expectEqual(core.mempool.Reason.missing_input, (try pool.check(child)).reason);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(parent)).reason);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(child)).reason);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "mutation classes are rejected with their reasons" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const prev = [_]u8{5} ** 32;
    const chain_prev = [_]u8{6} ** 32;
    try putCoin(&backend, prev, 0, 50, 1);
    try putCoin(&backend, chain_prev, 0, 50, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 1_000);
    defer pool.deinit();

    const good = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 40, &script_true, 0);
    defer allocator.free(good);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(good)).reason);

    try backend.putUtxo(.{ .txid = prev, .vout = 1 }, .{
        .height = 1,
        .vout = 1,
        .value_sats = 10,
        .coinbase = false,
        .script_pubkey = &script_false,
    });
    const failed_script = try rawTx(allocator, 2, prev, 1, 0xffffffff, &.{}, 1, &script_true, 0);
    defer allocator.free(failed_script);
    try std.testing.expectEqual(core.mempool.Reason.script_failed, (try pool.apply(failed_script)).reason);

    const in_pool = try rawTx(allocator, 2, prev, 0, 0xffffffff, &.{}, 30, &script_true, 0);
    defer allocator.free(in_pool);
    try std.testing.expectEqual(core.mempool.Reason.input_spent_in_pool, (try pool.apply(in_pool)).reason);

    try pool.coins.markChainSpend(.{ .txid = chain_prev, .vout = 0 });
    const on_chain = try rawTx(allocator, 2, chain_prev, 0, 0xffffffff, &.{}, 40, &script_true, 0);
    defer allocator.free(on_chain);
    try std.testing.expectEqual(core.mempool.Reason.input_spent_on_chain, (try pool.apply(on_chain)).reason);

    const locked_prev = [_]u8{7} ** 32;
    try putCoin(&backend, locked_prev, 0, 20, 1);
    const locked = try rawTx(allocator, 2, locked_prev, 0, 0xfffffffe, &.{}, 10, &script_true, 11);
    defer allocator.free(locked);
    try std.testing.expectEqual(core.mempool.Reason.locktime_unsatisfied, (try pool.apply(locked)).reason);

    const seq_prev = [_]u8{8} ** 32;
    try putCoin(&backend, seq_prev, 0, 20, 10);
    const sequenced = try rawTx(allocator, 2, seq_prev, 0, 1, &.{}, 10, &script_true, 0);
    defer allocator.free(sequenced);
    try std.testing.expectEqual(core.mempool.Reason.sequence_unsatisfied, (try pool.apply(sequenced)).reason);

    const coinbase = try rawTx(allocator, 2, [_]u8{0} ** 32, 0xffffffff, 0xffffffff, &.{}, 10, &script_true, 0);
    defer allocator.free(coinbase);
    try std.testing.expectEqual(core.mempool.Reason.coinbase, (try pool.apply(coinbase)).reason);
}

test "block connect evicts the confirmed transaction, the conflict, and the in-pool child" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    const a_prev = [_]u8{9} ** 32;
    const b_prev = [_]u8{10} ** 32;
    try putCoin(&backend, a_prev, 0, 40, 1);
    try putCoin(&backend, b_prev, 0, 40, 1);
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 10, 0);
    defer pool.deinit();
    const confirmed = try rawTx(allocator, 2, a_prev, 0, 0xffffffff, &.{}, 30, &script_true, 0);
    defer allocator.free(confirmed);
    const conflict = try rawTx(allocator, 2, b_prev, 0, 0xffffffff, &.{}, 30, &script_true, 0);
    defer allocator.free(conflict);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(confirmed)).reason);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(conflict)).reason);
    const confirmed_tx = try core.tx.deserialize(allocator, confirmed, 0);
    defer confirmed_tx.transaction.deinit(allocator);
    const child = try rawTx(allocator, 2, confirmed_tx.transaction.txid(), 0, 0xffffffff, &.{}, 20, &script_true, 0);
    defer allocator.free(child);
    try std.testing.expectEqual(core.mempool.Reason.accepted, (try pool.apply(child)).reason);

    const other = try rawTx(allocator, 2, b_prev, 0, 0xffffffff, &.{}, 25, &script_true, 0);
    defer allocator.free(other);
    const other_tx = try core.tx.deserialize(allocator, other, 0);
    defer other_tx.transaction.deinit(allocator);
    const txs = [_]core.tx.Transaction{ confirmed_tx.transaction, other_tx.transaction };
    const ids = [_][32]u8{ confirmed_tx.transaction.txid(), other_tx.transaction.txid() };
    try pool.onBlockConnected(&txs, &ids);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    const child_tx = try core.tx.deserialize(allocator, child, 0);
    defer child_tx.transaction.deinit(allocator);
    try std.testing.expect(!pool.by_txid.contains(child_tx.transaction.txid()));
}

test "disconnect replay is a loud stub" {
    const allocator = std.testing.allocator;
    var backend = core.coins_view.MemoryStore.init(allocator);
    defer backend.deinit();
    var pool = core.mempool.Pool(core.coins_view.MemoryStore).init(allocator, &backend, 1, 0);
    defer pool.deinit();
    try std.testing.expectError(error.DisconnectReplayNotImplemented, pool.restoreAfterDisconnect());
}
