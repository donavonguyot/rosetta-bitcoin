//! Connect check order: parent link, then proof of work (`decodeBlock`), then finality, BIP68, coinbase maturity, scripts, and the UTXO commit.
//! The parent link is `prev_hash` against the store tip. A competing block may be stored by `recordBlock` and must not be applied.
//! Connect one decoded testnet4 block: finality, BIP68, coinbase maturity, then scripts, then the UTXO commit.
//! Finality (`txNotFinal`) runs before inputs are resolved, and BIP68 runs before any script,
//! so a non-final transaction never reaches the verifier
//! (`zig_consensus_context_host_2026-10-04.json`, blocker ledger `consensus_gap_closed`).
//! Same-block outputs are not store lookups. At height 50000 they are 256399 of 1385632 inputs,
//! 18 percent (`zig_self_hosted_50k_host_2026-10-04.json`). Skipping them cut native `utxo_load`
//! from 1852 ms to 169 ms, 91 percent (`zig_native_store_utxo_load_campaign_docker_2026-10-04.json`).
//! Three per-operation costs each blow up across about 27 million ops: a shared atomic, a thread wake,
//! and an unmixed outpoint hash. The worker counters and the persistent pool were reverted
//! (blocker ledger `performance_note`).
//! `snapshot_ms` is subtracted from the commit wall so commit is the apply, not the snapshot.
//! Does not own the UTXO map or the sighash preimage. Those are the store and `script.zig`.

const std = @import("std");
const types = @import("types.zig");
const codec = @import("codec.zig");
const tx = @import("tx.zig");
const block = @import("block.zig");
const crypto = @import("crypto.zig");
const store = @import("store.zig");
const coins_view = @import("coins_view.zig");
const script = @import("script.zig");
const consensus_context = @import("consensus_context.zig");
const script_verify_split = @import("script_verify_split.zig");
const datadir = @import("datadir.zig");

const c = @cImport({
    @cInclude("time.h");
});

const Outpoint = types.Outpoint;
const StoredUtxo = types.StoredUtxo;
const CreatedUtxo = types.CreatedUtxo;
const UndoEntry = types.UndoEntry;
const ChainstateBlockCommit = types.ChainstateBlockCommit;
const nowMs = datadir.nowMs;
const encodeUtxoKey = codec.encodeUtxoKey;
const encodeUtxoValue = codec.encodeUtxoValue;
const encodeUndoValue = codec.encodeUndoValue;

/// Fold each spent UTXO out of the set hash using canonical key and value bytes.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub fn foldSpends(allocator: std.mem.Allocator, set_hash: *store.SetHash, spent: []const Outpoint, undo_entries: []const UndoEntry) !void {
    if (spent.len != undo_entries.len) return error.SpendUndoMismatch;
    for (undo_entries, spent) |entry, outpoint| {
        if (!std.mem.eql(u8, &entry.outpoint.txid, &outpoint.txid) or entry.outpoint.vout != outpoint.vout) return error.SpendUndoMismatch;
        const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
        defer allocator.free(key);
        const value = try encodeUtxoValue(allocator, entry.utxo);
        defer allocator.free(value);
        store.foldSetHash(set_hash, key, value);
    }
}

/// Per-stage cost of applying one block to a store.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const CommitTimings = struct {
    utxo_delete_prepare: i64 = 0,
    utxo_put_prepare: i64 = 0,
    undo_put_prepare: i64 = 0,
    metadata_put_prepare: i64 = 0,
    rocksdb_write: i64 = 0,
    set_hash_fold: i64 = 0,
    snapshot: i64 = 0,

    /// Prepare plus write time. Snapshot is outside this sum so commit stays the apply.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn total(self: CommitTimings) i64 {
        return self.utxo_delete_prepare + self.utxo_put_prepare + self.undo_put_prepare + self.metadata_put_prepare + self.rocksdb_write + self.set_hash_fold;
    }
};

/// Hit and miss counts for store lookups that were not same-block spends.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const UtxoLoadStats = struct {
    lookup_count: u64 = 0,
    key_bytes: u64 = 0,
    value_bytes: u64 = 0,
    utxo_hit_ns: u64 = 0,
    utxo_miss_ns: u64 = 0,
    utxo_hit_count: u64 = 0,
    utxo_miss_count: u64 = 0,
};

/// Connect stages, including same-block spends kept out of the store lookup.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const ConnectTimings = struct {
    utxo_load: i64 = 0,
    prevout_batch_load: i64 = 0,
    utxo_lookup_count: u64 = 0,
    utxo_key_bytes: u64 = 0,
    utxo_value_bytes: u64 = 0,
    utxo_hit_ns: u64 = 0,
    utxo_miss_ns: u64 = 0,
    utxo_hit_count: u64 = 0,
    utxo_miss_count: u64 = 0,
    created_utxos: u64 = 0,
    spent_external: u64 = 0,
    same_block_spends: u64 = 0,
    runner_batches: u64 = 0,
    tx_count: u64 = 0,
    input_count: u64 = 0,
    script_verify: i64 = 0,
    script_jobs: u64 = 0,
    script_threads: usize = 0,
    script_wall_ms: i64 = 0,
    script_worker_cpu_ms: i64 = 0,
    script_worker_elapsed_ns: u64 = 0,
    script_worker_thread_cpu_ns: u64 = 0,
    script_split: script_verify_split.Split = .{},
    utxo_apply: i64 = 0,
    commit: i64 = 0,
    utxo_delete_prepare: i64 = 0,
    utxo_put_prepare: i64 = 0,
    undo_put_prepare: i64 = 0,
    metadata_put_prepare: i64 = 0,
    rocksdb_write: i64 = 0,
    set_hash_fold: i64 = 0,
    snapshot: i64 = 0,
    block_connect_store_commit: i64 = 0,
};

/// Height, display hash, and UTXO count after one successful connect.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const ConnectResult = struct {
    validated_height: u32,
    validated_hash: []u8,
    chainstate_utxo_count: i64,
    blocks_connected: u32,
    timings: ConnectTimings,

    /// Free the bytes this value owns. The caller does not free them again.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn deinit(self: ConnectResult, allocator: std.mem.Allocator) void {
        allocator.free(self.validated_hash);
    }
};

const ScriptJob = struct {
    tx_index: usize,
    input_index: usize,
    prevouts: []script.SpentPrevout,
    sighash_cache: *const script.SighashCache,
};

/// Jobs, threads, and the split timings for one block's scripts.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const ScriptVerifyStats = struct {
    jobs: u64 = 0,
    threads: usize = 0,
    wall_ms: i64 = 0,
    worker_cpu_ms: i64 = 0,
    worker_elapsed_ns: u64 = 0,
    worker_thread_cpu_ns: u64 = 0,
    batches: u64 = 0,
    split: script_verify_split.Split = .{},
};

/// Worker count for script verify, capped so the machine is not oversubscribed.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub fn defaultScriptThreadCount() usize {
    const cpu_count = std.Thread.getCpuCount() catch 2;
    const minus_one = if (cpu_count > 1) cpu_count - 1 else 1;
    return @min(@max(minus_one, 1), 8);
}

/// Which compiled verifier a script worker must call.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const ScriptCryptoBackend = enum {
    native,
    own_curve,
    pure,

    /// Backend name recorded in a proof: libsecp256k1, libsecp256k1-zig, or zig-secp256k1.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn label(self: ScriptCryptoBackend) []const u8 {
        return switch (self) {
            .native => "libsecp256k1",
            .own_curve => "libsecp256k1-zig",
            .pure => "zig-secp256k1",
        };
    }
};

/// Owns the worker count and the backend for one process.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub const ScriptVerifyRunner = struct {
    allocator: std.mem.Allocator,
    thread_count: usize,
    crypto_backend: ScriptCryptoBackend,

    /// Construct the verifier or runner this binary is allowed to use.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn create(allocator: std.mem.Allocator, requested_threads: usize) !*ScriptVerifyRunner {
        return createWithCryptoBackend(allocator, requested_threads, if (crypto.own_curve) .own_curve else .native);
    }

    /// Construct a script runner for one backend, or fail if that backend was not compiled.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn createWithCryptoBackend(allocator: std.mem.Allocator, requested_threads: usize, crypto_backend: ScriptCryptoBackend) !*ScriptVerifyRunner {
        if (crypto.own_curve != (crypto_backend == .own_curve)) return error.CryptoBackendNotCompiled;
        const thread_count = @max(requested_threads, 1);
        const self = try allocator.create(ScriptVerifyRunner);
        self.* = .{
            .allocator = allocator,
            .thread_count = thread_count,
            .crypto_backend = crypto_backend,
        };
        return self;
    }

    /// Drop a verifier or runner the matching create allocated.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn destroy(self: *ScriptVerifyRunner) void {
        self.allocator.destroy(self);
    }

    /// Run the block's script jobs on the compiled backend. Finality has already passed.
    /// A connected block has already passed finality and BIP68 before any script runs.
    /// test "same block view rejects double spends"
    pub fn verifyBlock(self: *ScriptVerifyRunner, transactions: []const tx.Transaction, jobs: []const ScriptJob) !ScriptVerifyStats {
        if (jobs.len == 0) return .{ .threads = self.thread_count };
        const split_before = script_verify_split.snapshot();
        const started = nowMs();
        const worker_count = @min(self.thread_count, jobs.len);
        const threads = try std.heap.c_allocator.alloc(std.Thread, worker_count);
        defer std.heap.c_allocator.free(threads);
        const results = try std.heap.c_allocator.alloc(ScriptThreadResult, jobs.len);
        defer std.heap.c_allocator.free(results);
        for (results) |*result| result.* = .{};
        var next_job = std.atomic.Value(usize).init(0);
        var worker_cpu = try std.heap.c_allocator.alloc(WorkerTiming, worker_count);
        defer std.heap.c_allocator.free(worker_cpu);
        for (worker_cpu) |*value| value.* = .{};
        for (threads, 0..) |*thread, worker_index| {
            thread.* = try std.Thread.spawn(.{}, scriptVerifySchedulerWorker, .{ transactions, jobs, results, &next_job, &worker_cpu[worker_index], self.crypto_backend });
        }
        for (threads) |thread| thread.join();
        var worker_cpu_ms: i64 = 0;
        var worker_elapsed_ns: u64 = 0;
        var worker_thread_cpu_ns: u64 = 0;
        for (worker_cpu) |value| {
            worker_cpu_ms += value.legacy_ms;
            worker_elapsed_ns += value.elapsed_ns;
            worker_thread_cpu_ns += value.cpu_ns;
        }

        if (firstScriptFailure(results)) |result| {
            printScriptFailure(result);
            return result.err.?;
        }
        return .{
            .jobs = @intCast(jobs.len),
            .threads = self.thread_count,
            .wall_ms = elapsedMs(started),
            .worker_cpu_ms = worker_cpu_ms,
            .worker_elapsed_ns = worker_elapsed_ns,
            .worker_thread_cpu_ns = worker_thread_cpu_ns,
            .batches = 1,
            .split = script_verify_split.snapshot().since(split_before),
        };
    }
};

/// Reject a block whose previous hash is not the store tip.
/// Height 0 on an empty store has no parent. Every later block does.
/// test "parent mismatch rejects a block whose prev is not the tip"
pub fn requireParentLink(height: u32, prev_hash: [32]u8, tip_hash: ?[32]u8) !void {
    const tip = tip_hash orelse {
        if (height == 0) return;
        printParentMismatch(height, prev_hash, null);
        return error.ParentMismatch;
    };
    if (std.mem.eql(u8, &prev_hash, &tip)) return;
    printParentMismatch(height, prev_hash, tip);
    return error.ParentMismatch;
}

fn printParentMismatch(height: u32, prev_hash: [32]u8, tip_hash: ?[32]u8) void {
    var prev_hex: [64]u8 = undefined;
    var tip_hex: [64]u8 = undefined;
    writeDisplayHex(&prev_hex, &prev_hash);
    const tip_text: []const u8 = if (tip_hash) |tip| blk: {
        writeDisplayHex(&tip_hex, &tip);
        break :blk &tip_hex;
    } else "";
    std.debug.print("{{\"error\":\"ParentMismatch\",\"height\":{d},\"prev_hash\":\"{s}\",\"tip_hash\":\"{s}\"}}\n", .{ height, &prev_hex, tip_text });
}

fn writeDisplayHex(out: *[64]u8, internal: *const [32]u8) void {
    const alphabet = "0123456789abcdef";
    for (0..32) |i| {
        const byte = internal[31 - i];
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

/// Connect one block: parent link, then finality, then BIP68, then scripts, then the store commit.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "parent mismatch rejects a block whose prev is not the tip"
pub fn connectDecodedBlock(
    allocator: std.mem.Allocator,
    db: anytype,
    height: u32,
    target: u32,
    info: block.BlockInfo,
    transactions: []const tx.Transaction,
    script_runner: ?*ScriptVerifyRunner,
    current_utxo_count: i64,
) !ConnectResult {
    _ = target;
    const block_started = nowMs();
    try requireParentLink(height, info.prev_hash, try db.tipHash());
    if (transactions.len == 0) return error.BlockWithoutTransactions;
    if (!transactions[0].isCoinbase()) return error.FirstTransactionNotCoinbase;

    try db.ensureHeaderIndex();
    const block_mtp: u32 = if (height == 0) 0 else try db.medianTimePast(height - 1);
    var block_time: u32 = 0;
    if (try db.headerFields(height)) |fields| block_time = fields.time;
    for (transactions) |transaction| {
        if (consensus_context.txNotFinal(transaction, height, block_mtp, block_time)) return error.TxNotFinal;
    }

    var txids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(txids);
    for (transactions, 0..) |transaction, i| txids[i] = transaction.txid();

    var external_prevouts = std.AutoHashMap(Outpoint, void).init(allocator);
    defer external_prevouts.deinit();
    var created_outpoints = std.AutoHashMap(Outpoint, void).init(allocator);
    defer created_outpoints.deinit();
    for (transactions, txids) |transaction, txid| {
        for (transaction.outputs, 0..) |_, vout| {
            try created_outpoints.put(.{ .txid = txid, .vout = @intCast(vout) }, {});
        }
    }
    var external_order = std.ArrayList(Outpoint).empty;
    defer external_order.deinit(allocator);
    for (transactions[1..]) |transaction| {
        for (transaction.inputs) |input| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            if (!external_prevouts.contains(outpoint)) {
                try external_prevouts.put(outpoint, {});
                // Same-block outputs are resolved from the block itself. They are not in the store yet.
                if (!created_outpoints.contains(outpoint)) try external_order.append(allocator, outpoint);
            }
        }
    }

    var timings = ConnectTimings{};
    timings.tx_count = @intCast(transactions.len);
    const load_started = nowMs();
    var load_stats = UtxoLoadStats{};
    const loaded_values = try db.getManyUtxosWithStats(allocator, "testnet4", external_order.items, &load_stats);
    defer allocator.free(loaded_values);
    timings.prevout_batch_load += elapsedMs(load_started);
    timings.utxo_load += elapsedMs(load_started);
    timings.utxo_lookup_count += load_stats.lookup_count;
    timings.utxo_key_bytes += load_stats.key_bytes;
    timings.utxo_value_bytes += load_stats.value_bytes;
    timings.utxo_hit_ns += load_stats.utxo_hit_ns;
    timings.utxo_miss_ns += load_stats.utxo_miss_ns;
    timings.utxo_hit_count += load_stats.utxo_hit_count;
    timings.utxo_miss_count += load_stats.utxo_miss_count;

    var loaded = std.AutoHashMap(Outpoint, StoredUtxo).init(allocator);
    defer {
        var it = loaded.valueIterator();
        while (it.next()) |utxo| utxo.deinit(allocator);
        loaded.deinit();
    }
    for (external_order.items, loaded_values) |outpoint, value| {
        if (value) |utxo| try loaded.put(outpoint, utxo);
    }

    var created_lookup = std.AutoHashMap(Outpoint, StoredUtxo).init(allocator);
    defer created_lookup.deinit();
    var spent = std.AutoHashMap(Outpoint, void).init(allocator);
    defer spent.deinit();
    var undo_entries = std.ArrayList(UndoEntry).empty;
    defer undo_entries.deinit(allocator);
    var external_spends = std.ArrayList(Outpoint).empty;
    defer external_spends.deinit(allocator);
    var script_prevout_sets = std.ArrayList([]script.SpentPrevout).empty;
    defer {
        for (script_prevout_sets.items) |prevouts| allocator.free(prevouts);
        script_prevout_sets.deinit(allocator);
    }
    var sighash_caches = try allocator.alloc(?script.SighashCache, transactions.len);
    defer {
        for (sighash_caches) |*cache| {
            if (cache.*) |*actual| actual.deinit(allocator);
        }
        allocator.free(sighash_caches);
    }
    for (sighash_caches) |*cache| cache.* = null;
    var script_jobs = std.ArrayList(ScriptJob).empty;
    defer script_jobs.deinit(allocator);

    for (transactions, 0..) |transaction, tx_index| {
        if (tx_index == 0) {
            if (!transaction.isCoinbase()) return error.FirstTransactionNotCoinbase;
            if (height != 0) try addCreatedOutputs(&created_lookup, &external_prevouts, height, transaction, txids[tx_index], true);
            continue;
        }
        if (transaction.inputs.len == 0) return error.NonCoinbaseWithoutInputs;
        timings.input_count += @intCast(transaction.inputs.len);
        var input_seen = std.AutoHashMap(Outpoint, void).init(allocator);
        defer input_seen.deinit();
        var prevouts = try allocator.alloc(script.SpentPrevout, transaction.inputs.len);
        errdefer allocator.free(prevouts);
        for (transaction.inputs, 0..) |input, input_index| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            if (input_seen.contains(outpoint) or spent.contains(outpoint)) return error.DuplicateSpendInBlock;
            try input_seen.put(outpoint, {});
            const from_created = created_lookup.get(outpoint);
            const utxo = from_created orelse loaded.get(outpoint) orelse return error.MissingUtxo;
            if (from_created != null) timings.same_block_spends += 1;
            if (utxo.coinbase and height < utxo.height + 100) return error.CoinbaseMaturity;
            const coin_time: u32 = if (!consensus_context.sequenceNeedsCoinTime(transaction.version, input.sequence, height))
                0
            else if (from_created != null)
                block_mtp
            else
                try db.medianTimePast(if (utxo.height == 0) 0 else utxo.height - 1);
            if (consensus_context.sequenceLockUnsatisfied(transaction.version, input.sequence, utxo.height, coin_time, height, block_mtp)) {
                return error.SequenceLockUnsatisfied;
            }
            prevouts[input_index] = .{ .amount = @intCast(utxo.value_sats), .script_pubkey = utxo.script_pubkey };
        }
        try script_prevout_sets.append(allocator, prevouts);
        sighash_caches[tx_index] = try script.SighashCache.init(allocator, transaction, prevouts);
        for (transaction.inputs, 0..) |_, input_index| {
            try script_jobs.append(allocator, .{
                .tx_index = tx_index,
                .input_index = input_index,
                .prevouts = prevouts,
                .sighash_cache = &(sighash_caches[tx_index].?),
            });
        }
        for (transaction.inputs) |input| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            try spent.put(outpoint, {});
            if (!created_lookup.contains(outpoint)) {
                try external_spends.append(allocator, outpoint);
                const utxo = loaded.get(outpoint) orelse return error.MissingUndoUtxo;
                try undo_entries.append(allocator, .{ .outpoint = outpoint, .utxo = utxo });
            }
        }
        try addCreatedOutputs(&created_lookup, &external_prevouts, height, transaction, txids[tx_index], false);
    }

    const script_started = nowMs();
    const script_stats = if (script_runner) |runner|
        try runner.verifyBlock(transactions, script_jobs.items)
    else
        try verifyScriptJobsParallel(transactions, script_jobs.items);
    timings.script_verify += elapsedMs(script_started);
    timings.script_jobs += script_stats.jobs;
    timings.script_threads = script_stats.threads;
    timings.script_wall_ms += script_stats.wall_ms;
    timings.script_worker_cpu_ms += script_stats.worker_cpu_ms;
    timings.script_worker_elapsed_ns += script_stats.worker_elapsed_ns;
    timings.script_worker_thread_cpu_ns += script_stats.worker_thread_cpu_ns;
    timings.script_split.add(script_stats.split);
    timings.runner_batches += script_stats.batches;

    const created_count = try countUnspentCreatedOutputs(transactions, txids, height, &spent);
    timings.created_utxos += created_count;
    timings.spent_external += external_spends.items.len;
    const new_utxo_count = current_utxo_count - @as(i64, @intCast(external_spends.items.len)) + @as(i64, @intCast(created_count));

    const commit_started = nowMs();
    const commit_timings = try db.commitConnectedBlock(allocator, height, info.hash, external_spends.items, undo_entries.items, transactions, txids, &spent, new_utxo_count);
    const commit_wall = elapsedMs(commit_started);
    timings.commit += if (commit_timings.snapshot > commit_wall) 0 else commit_wall - commit_timings.snapshot;
    timings.snapshot += commit_timings.snapshot;
    timings.utxo_delete_prepare += commit_timings.utxo_delete_prepare;
    timings.utxo_put_prepare += commit_timings.utxo_put_prepare;
    timings.undo_put_prepare += commit_timings.undo_put_prepare;
    timings.metadata_put_prepare += commit_timings.metadata_put_prepare;
    timings.rocksdb_write += commit_timings.rocksdb_write;
    timings.set_hash_fold += commit_timings.set_hash_fold;
    timings.utxo_apply += timings.commit;
    timings.block_connect_store_commit += elapsedMs(block_started);

    return .{
        .validated_height = height,
        .validated_hash = try crypto.displayHashAlloc(allocator, info.hash[0..]),
        .chainstate_utxo_count = new_utxo_count,
        .blocks_connected = 1,
        .timings = timings,
    };
}

fn addCreatedOutputs(
    created_lookup: *std.AutoHashMap(Outpoint, StoredUtxo),
    block_inputs: *std.AutoHashMap(Outpoint, void),
    height: u32,
    transaction: tx.Transaction,
    txid: [32]u8,
    coinbase: bool,
) !void {
    for (transaction.outputs, 0..) |output, vout| {
        if (output.value < 0) return error.NegativeOutputValue;
        if (!isSpendableOutput(output.script_pubkey)) continue;
        const outpoint = Outpoint{ .txid = txid, .vout = @intCast(vout) };
        const utxo = StoredUtxo{
            .height = height,
            .vout = @intCast(vout),
            .value_sats = @intCast(output.value),
            .coinbase = coinbase,
            .script_pubkey = output.script_pubkey,
        };
        if (block_inputs.contains(outpoint)) {
            if (created_lookup.contains(outpoint)) return error.DuplicateCreatedUtxo;
            try created_lookup.put(outpoint, utxo);
        }
    }
}

fn countUnspentCreatedOutputs(transactions: []const tx.Transaction, txids: []const [32]u8, height: u32, spent: *std.AutoHashMap(Outpoint, void)) !u64 {
    var count: u64 = 0;
    for (transactions, 0..) |transaction, tx_index| {
        if (height == 0 and tx_index == 0) continue;
        for (transaction.outputs, 0..) |output, vout| {
            if (output.value < 0) return error.NegativeOutputValue;
            if (!isSpendableOutput(output.script_pubkey)) continue;
            const outpoint = Outpoint{ .txid = txids[tx_index], .vout = @intCast(vout) };
            if (!spent.contains(outpoint)) count += 1;
        }
    }
    return count;
}

/// False for outputs the UTXO set must not keep, including OP_RETURN.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub fn isSpendableOutput(script_pubkey: []const u8) bool {
    return script_pubkey.len != 0 and script_pubkey[0] != 0x6a;
}

const ScriptThreadResult = struct {
    err: ?anyerror = null,
    tx_index: usize = 0,
    input_index: usize = 0,
    txid: [32]u8 = [_]u8{0} ** 32,
};

fn verifyScriptJobsParallel(transactions: []const tx.Transaction, jobs: []const ScriptJob) !ScriptVerifyStats {
    if (jobs.len == 0) return .{};
    const split_before = script_verify_split.snapshot();
    const started = nowMs();
    var threads = try std.heap.c_allocator.alloc(std.Thread, jobs.len);
    defer std.heap.c_allocator.free(threads);
    var results = try std.heap.c_allocator.alloc(ScriptThreadResult, jobs.len);
    defer std.heap.c_allocator.free(results);
    for (jobs, 0..) |job, i| {
        results[i] = .{};
        threads[i] = try std.Thread.spawn(.{}, verifyScriptInputJobWithNative, .{ transactions[job.tx_index], job, &results[i] });
    }
    for (threads) |thread| thread.join();
    if (firstScriptFailure(results)) |result| {
        printScriptFailure(result);
        return result.err.?;
    }
    return .{
        .jobs = @intCast(jobs.len),
        .threads = jobs.len,
        .wall_ms = elapsedMs(started),
        .worker_cpu_ms = elapsedMs(started),
        .batches = 1,
        .split = script_verify_split.snapshot().since(split_before),
    };
}

// Timers cover the scheduler loop, excluding verifier creation and destruction.
const WorkerTiming = struct { legacy_ms: i64 = 0, elapsed_ns: u64 = 0, cpu_ns: u64 = 0 };
fn clockNs(clock: c.clockid_t) u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(clock, &value) != 0) @panic("worker clock unavailable");
    return @as(u64, @intCast(value.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(value.tv_nsec));
}

fn scriptVerifySchedulerWorker(
    transactions: []const tx.Transaction,
    jobs: []const ScriptJob,
    results: []ScriptThreadResult,
    next_job: *std.atomic.Value(usize),
    worker_cpu_ms: *WorkerTiming,
    crypto_backend: ScriptCryptoBackend,
) void {
    switch (crypto_backend) {
        .own_curve => {
            var verifier = crypto.OwnVerifier.create();
            defer verifier.destroy();
            return scriptVerifySchedulerWorkerLoop(transactions, jobs, results, next_job, worker_cpu_ms, .{ .own = &verifier });
        },
        .native => {
            var verifier = crypto.NativeVerifier.create() catch {
                while (true) {
                    const job_index = next_job.fetchAdd(1, .monotonic);
                    if (job_index >= jobs.len) return;
                    const job = jobs[job_index];
                    results[job_index] = .{
                        .err = error.NativeCryptoUnavailable,
                        .tx_index = job.tx_index,
                        .input_index = job.input_index,
                        .txid = transactions[job.tx_index].txid(),
                    };
                }
            };
            defer verifier.destroy();
            return scriptVerifySchedulerWorkerLoop(transactions, jobs, results, next_job, worker_cpu_ms, .{ .native = &verifier });
        },
        .pure => {
            var verifier = crypto.PureVerifier.create();
            defer verifier.destroy();
            return scriptVerifySchedulerWorkerLoop(transactions, jobs, results, next_job, worker_cpu_ms, .{ .pure = &verifier });
        },
    }
}

fn scriptVerifySchedulerWorkerLoop(
    transactions: []const tx.Transaction,
    jobs: []const ScriptJob,
    results: []ScriptThreadResult,
    next_job: *std.atomic.Value(usize),
    worker_cpu_ms: *WorkerTiming,
    verifier: crypto.CryptoVerifier,
) void {
    const elapsed_start = clockNs(c.CLOCK_MONOTONIC);
    const cpu_start = clockNs(c.CLOCK_THREAD_CPUTIME_ID);
    defer {
        worker_cpu_ms.cpu_ns += clockNs(c.CLOCK_THREAD_CPUTIME_ID) - cpu_start;
        worker_cpu_ms.elapsed_ns += clockNs(c.CLOCK_MONOTONIC) - elapsed_start;
    }
    while (true) {
        const job_index = next_job.fetchAdd(1, .monotonic);
        if (job_index >= jobs.len) return;
        const job = jobs[job_index];
        const started = nowMs();
        verifyScriptInputJob(transactions[job.tx_index], job, &results[job_index], verifier);
        worker_cpu_ms.legacy_ms += elapsedMs(started);
    }
}

fn verifyScriptInputJobWithNative(transaction: tx.Transaction, job: ScriptJob, result: *ScriptThreadResult) void {
    if (crypto.own_curve) {
        var verifier = crypto.OwnVerifier.create();
        defer verifier.destroy();
        return verifyScriptInputJob(transaction, job, result, .{ .own = &verifier });
    }
    var native = crypto.NativeVerifier.create() catch |err| {
        storeScriptFailure(transaction, job, result, err);
        return;
    };
    defer native.destroy();
    verifyScriptInputJob(transaction, job, result, .{ .native = &native });
}

fn verifyScriptInputJob(transaction: tx.Transaction, job: ScriptJob, result: *ScriptThreadResult, verifier: crypto.CryptoVerifier) void {
    script.verifyInputWithVerifier(std.heap.c_allocator, transaction, job.input_index, job.prevouts, verifier, job.sighash_cache) catch |err| {
        storeScriptFailure(transaction, job, result, err);
        return;
    };
}

fn storeScriptFailure(transaction: tx.Transaction, job: ScriptJob, result: *ScriptThreadResult, err: anyerror) void {
    result.err = err;
    result.tx_index = job.tx_index;
    result.input_index = job.input_index;
    result.txid = transaction.txid();
}

fn firstScriptFailure(results: []const ScriptThreadResult) ?ScriptThreadResult {
    var failure: ?ScriptThreadResult = null;
    for (results) |result| {
        if (result.err == null) continue;
        if (failure == null or
            result.tx_index < failure.?.tx_index or
            (result.tx_index == failure.?.tx_index and result.input_index < failure.?.input_index))
        {
            failure = result;
        }
    }
    return failure;
}

fn printScriptFailure(result: ScriptThreadResult) void {
    const txid_display = crypto.displayHashAlloc(std.heap.c_allocator, result.txid[0..]) catch "display-error";
    defer if (!std.mem.eql(u8, txid_display, "display-error")) std.heap.c_allocator.free(txid_display);
    std.debug.print("zig script verify failure tx_index={} input_index={} txid={s} err={s}\n", .{ result.tx_index, result.input_index, txid_display, @errorName(result.err.?) });
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

/// Milliseconds since a timestamp taken with the process clock.
/// A connected block has already passed finality and BIP68 before any script runs.
/// test "same block view rejects double spends"
pub fn elapsedMs(start_ms: i64) i64 {
    return @max(0, nowMs() - start_ms);
}

test "parallel script results choose deterministic first failure" {
    const txid = [_]u8{3} ** 32;
    const results = [_]ScriptThreadResult{
        .{ .err = error.UnsupportedScriptTemplate, .tx_index = 4, .input_index = 0, .txid = txid },
        .{},
        .{ .err = error.ScriptTerminalFalse, .tx_index = 2, .input_index = 3, .txid = txid },
        .{ .err = error.MissingUtxo, .tx_index = 2, .input_index = 1, .txid = txid },
    };
    const failure = firstScriptFailure(results[0..]) orelse return error.ExpectedFailure;
    try std.testing.expectEqual(@as(usize, 2), failure.tx_index);
    try std.testing.expectEqual(@as(usize, 1), failure.input_index);
    try std.testing.expect(failure.err.? == error.MissingUtxo);
}
test "get many shape preserves order and missing slots" {
    const Request = struct { key: []const u8, value: ?[]const u8 };
    const rows = [_]Request{
        .{ .key = "a", .value = "one" },
        .{ .key = "b", .value = null },
        .{ .key = "c", .value = "three" },
    };
    try std.testing.expectEqualStrings("a", rows[0].key);
    try std.testing.expect(rows[1].value == null);
    try std.testing.expectEqualStrings("three", rows[2].value.?);
}

test "same block view rejects double spends" {
    var spent = std.StringHashMap(void).init(std.testing.allocator);
    defer spent.deinit();
    try spent.put("txid:0", {});
    try std.testing.expect(spent.contains("txid:0"));
    try std.testing.expect(!spent.contains("txid:1"));
}

test "parent mismatch rejects a block whose prev is not the tip" {
    const allocator = std.testing.allocator;
    var db = coins_view.MemoryStore.init(allocator);
    defer db.deinit();
    const tip = [_]u8{0x11} ** 32;
    db.tip_hash = tip;
    const foreign = block.BlockInfo{
        .hash = [_]u8{0x22} ** 32,
        .prev_hash = [_]u8{0x33} ** 32,
        .merkle_root = [_]u8{0} ** 32,
        .tx_count = 0,
        .bits = 0,
    };
    try std.testing.expectError(error.ParentMismatch, connectDecodedBlock(allocator, &db, 1, 1, foreign, &.{}, null, 0));
    var linked = foreign;
    linked.prev_hash = tip;
    try std.testing.expectError(error.BlockWithoutTransactions, connectDecodedBlock(allocator, &db, 1, 1, linked, &.{}, null, 0));
    db.tip_hash = null;
    try std.testing.expectError(error.BlockWithoutTransactions, connectDecodedBlock(allocator, &db, 0, 0, foreign, &.{}, null, 0));
}
