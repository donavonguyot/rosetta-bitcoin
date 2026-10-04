const std = @import("std");
const root = @import("root.zig");
const mempool = @import("mempool.zig");
const tx = root.tx;
const crypto = root.crypto;
const block = root.block;

pub const MAX_BLOCK_WEIGHT: u64 = 4_000_000;
pub const MAX_SIGOP_COST: u32 = 80_000;
pub const POW_LIMIT_BITS: u32 = 0x1d00ffff;
const TARGET_TIMESPAN: i64 = 14 * 24 * 60 * 60;
const TARGET_SPACING: u32 = 600;
const MAX_TIMEWARP: u32 = 600;

pub const Assembly = struct {
    height: u32,
    prev_hash: [32]u8,
    time: u32,
    bits: u32,
    fees: u64,
    transactions: []const tx.Transaction,
};

pub fn subsidy(height: u32) u64 {
    return @as(u64, 5_000_000_000) >> @intCast(height / 210_000);
}

pub fn headerTimeFor(mtp: u32, now: u32, height: u32, prev_time: u32) u32 {
    var stamp = @max(mtp +% 1, now);
    if (height % 2016 == 0 and height > 0) {
        const floor: u32 = if (prev_time > MAX_TIMEWARP) prev_time - MAX_TIMEWARP else 0;
        if (stamp < floor) stamp = floor;
    }
    return stamp;
}

pub fn nextBits(store: anytype, allocator: std.mem.Allocator, height: u32, time: u32) !u32 {
    if (height == 0) return POW_LIMIT_BITS;
    const prev_height = height - 1;
    const prev = (try store.headerAt(allocator, prev_height)) orelse return error.MissingHeader;
    const prev_time = std.mem.readInt(u32, prev[68..72], .little);
    const prev_bits = std.mem.readInt(u32, prev[72..76], .little);
    if (height % 2016 != 0) {
        if (time > prev_time +% (TARGET_SPACING * 2)) return POW_LIMIT_BITS;
        var cursor = prev_height;
        var bits = prev_bits;
        while (cursor > 0 and cursor % 2016 != 0 and bits == POW_LIMIT_BITS) {
            cursor -= 1;
            const header = (try store.headerAt(allocator, cursor)) orelse return error.MissingHeader;
            bits = std.mem.readInt(u32, header[72..76], .little);
        }
        return bits;
    }
    const first_height = prev_height - (prev_height % 2016);
    const first = (try store.headerAt(allocator, first_height)) orelse return error.MissingHeader;
    const first_time = std.mem.readInt(u32, first[68..72], .little);
    const first_bits = std.mem.readInt(u32, first[72..76], .little);
    return retarget(first_bits, first_time, prev_time);
}

fn retarget(first_bits: u32, first_time: u32, prev_time: u32) !u32 {
    const raw: i64 = @as(i64, prev_time) - @as(i64, first_time);
    const span = std.math.clamp(raw, @divTrunc(TARGET_TIMESPAN, 4), TARGET_TIMESPAN * 4);
    const base = try compactTargetLe(first_bits);
    const limit = try compactTargetLe(POW_LIMIT_BITS);
    const scaled = mulDiv256(base, @intCast(span), @intCast(TARGET_TIMESPAN));
    const capped = if (greaterLe(scaled, limit)) limit else scaled;
    return compactFromTarget(capped);
}

pub fn coinbaseWeight(allocator: std.mem.Allocator, height: u32) !struct { weight: u64, sigops: u32 } {
    const coinbase = try buildCoinbase(allocator, height, 0, &.{});
    defer coinbase.deinit(allocator);
    return .{
        .weight = try mempool.transactionWeight(allocator, coinbase),
        .sigops = mempool.sigopCost(coinbase, &.{}),
    };
}

pub fn assemble(allocator: std.mem.Allocator, input: Assembly) ![]u8 {
    const coinbase = try buildCoinbase(allocator, input.height, input.fees, input.transactions);
    defer coinbase.deinit(allocator);
    var all = try allocator.alloc(tx.Transaction, input.transactions.len + 1);
    defer allocator.free(all);
    all[0] = coinbase;
    @memcpy(all[1..], input.transactions);

    var txids = try allocator.alloc([32]u8, all.len);
    defer allocator.free(txids);
    for (all, 0..) |transaction, i| txids[i] = transaction.txid();
    const merkle = try block.merkleRoot(allocator, txids);

    var header: [80]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 0x20000000, .little);
    @memcpy(header[4..36], input.prev_hash[0..]);
    @memcpy(header[36..68], merkle[0..]);
    std.mem.writeInt(u32, header[68..72], input.time, .little);
    std.mem.writeInt(u32, header[72..76], input.bits, .little);
    std.mem.writeInt(u32, header[76..80], 0, .little);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &header);
    try tx.writeCompactSize(allocator, &out, all.len);
    for (all) |transaction| {
        const raw = try tx.serialize(allocator, transaction, true);
        defer allocator.free(raw);
        try out.appendSlice(allocator, raw);
    }
    return out.toOwnedSlice(allocator);
}

fn buildCoinbase(allocator: std.mem.Allocator, height: u32, fees: u64, others: []const tx.Transaction) !tx.Transaction {
    const script_sig = try bip34ScriptSig(allocator, height);
    errdefer allocator.free(script_sig);
    var inputs = try allocator.alloc(tx.TxIn, 1);
    errdefer allocator.free(inputs);
    inputs[0] = .{
        .previous_output = .{ .hash = [_]u8{0} ** 32, .index = 0xffffffff },
        .script_sig = script_sig,
        .sequence = 0xffffffff,
    };
    const commitment = try witnessCommitment(allocator, others);
    const value: u64 = subsidy(height) + fees;
    var outputs = try allocator.alloc(tx.TxOut, 2);
    errdefer allocator.free(outputs);
    const anyone = try allocator.dupe(u8, &[_]u8{0x51});
    errdefer allocator.free(anyone);
    const commit_script = try allocator.alloc(u8, 38);
    errdefer allocator.free(commit_script);
    commit_script[0] = 0x6a;
    commit_script[1] = 0x24;
    commit_script[2] = 0xaa;
    commit_script[3] = 0x21;
    commit_script[4] = 0xa9;
    commit_script[5] = 0xed;
    @memcpy(commit_script[6..38], commitment[0..]);
    outputs[0] = .{ .value = @intCast(value), .script_pubkey = anyone };
    outputs[1] = .{ .value = 0, .script_pubkey = commit_script };

    var witness_item = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(witness_item);
    witness_item[0] = try allocator.dupe(u8, &([_]u8{0} ** 32));
    errdefer allocator.free(witness_item[0]);
    var witness = try allocator.alloc([]const []const u8, 1);
    errdefer allocator.free(witness);
    witness[0] = witness_item;

    const bare = tx.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .witness = &.{},
        .raw_no_witness = &.{},
    };
    const raw_no_witness = try tx.serializeNoWitness(allocator, bare);
    return .{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .witness = witness,
        .raw_no_witness = raw_no_witness,
    };
}

fn bip34ScriptSig(allocator: std.mem.Allocator, height: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try pushScriptNum(allocator, &out, height);
    const tag = "RosettaBitcoin/zig";
    try out.append(allocator, @intCast(tag.len));
    try out.appendSlice(allocator, tag);
    return out.toOwnedSlice(allocator);
}

fn pushScriptNum(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    if (value == 0) {
        try out.append(allocator, 0x00);
        return;
    }
    if (value >= 1 and value <= 16) {
        try out.append(allocator, @intCast(0x50 + value));
        return;
    }
    var buf: [5]u8 = undefined;
    var n: usize = 0;
    var rest = value;
    while (rest > 0) : (n += 1) {
        buf[n] = @truncate(rest);
        rest >>= 8;
    }
    if ((buf[n - 1] & 0x80) != 0) {
        buf[n] = 0x00;
        n += 1;
    }
    try out.append(allocator, @intCast(n));
    try out.appendSlice(allocator, buf[0..n]);
}

pub fn witnessCommitment(allocator: std.mem.Allocator, others: []const tx.Transaction) ![32]u8 {
    var wtxids = try allocator.alloc([32]u8, others.len + 1);
    defer allocator.free(wtxids);
    wtxids[0] = [_]u8{0} ** 32;
    for (others, 1..) |transaction, i| wtxids[i] = try transaction.wtxid(allocator);
    const witness_root = try block.merkleRoot(allocator, wtxids);
    var payload: [64]u8 = undefined;
    @memcpy(payload[0..32], witness_root[0..]);
    @memset(payload[32..64], 0);
    return crypto.doubleSha256(payload[0..]);
}

pub const ParsedTemplate = struct {
    info: block.BlockInfo,
    transactions: []tx.Transaction,

    pub fn deinit(self: ParsedTemplate, allocator: std.mem.Allocator) void {
        for (self.transactions) |transaction| transaction.deinit(allocator);
        allocator.free(self.transactions);
    }
};

/// Block bytes without the proof-of-work check. Merkle root and witness commitment are checked.
pub fn parseTemplate(allocator: std.mem.Allocator, raw: []const u8) !ParsedTemplate {
    if (raw.len < 81) return error.BlockTooShort;
    const header = raw[0..80];
    const hash = crypto.doubleSha256(header);
    var prev: [32]u8 = undefined;
    @memcpy(&prev, header[4..36]);
    const bits = std.mem.readInt(u32, header[72..76], .little);
    const transactions = try tx.parseBlockTransactions(allocator, raw);
    errdefer {
        for (transactions) |transaction| transaction.deinit(allocator);
        allocator.free(transactions);
    }
    var txids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(txids);
    for (transactions, 0..) |transaction, i| txids[i] = transaction.txid();
    const merkle = try block.merkleRoot(allocator, txids);
    if (!std.mem.eql(u8, merkle[0..], header[36..68])) return error.BlockMerkleMismatch;
    try block.validateWitnessCommitment(allocator, transactions);
    return .{
        .info = .{ .hash = hash, .prev_hash = prev, .merkle_root = merkle, .tx_count = transactions.len, .bits = bits },
        .transactions = transactions,
    };
}

pub fn checkTemplateLimits(allocator: std.mem.Allocator, transactions: []const tx.Transaction) !void {
    var seen = std.AutoHashMap([32]u8, void).init(allocator);
    defer seen.deinit();
    var weight: u64 = 0;
    for (transactions) |transaction| {
        const txid = transaction.txid();
        if (seen.contains(txid)) return error.DuplicateTxid;
        try seen.put(txid, {});
        weight += try mempool.transactionWeight(allocator, transaction);
    }
    if (weight > MAX_BLOCK_WEIGHT) return error.BlockWeightExceeded;
}

pub fn DiscardingStore(comptime Inner: type) type {
    return struct {
        const Self = @This();
        inner: *Inner,

        pub fn headerAt(self: *Self, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
            return self.inner.headerAt(allocator, height);
        }

        pub fn getManyUtxosWithStats(self: *Self, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const root.Outpoint, stats: ?*root.UtxoLoadStats) ![]?root.StoredUtxo {
            return self.inner.getManyUtxosWithStats(allocator, chain, outpoints, stats);
        }

        pub fn commitConnectedBlock(
            self: *Self,
            allocator: std.mem.Allocator,
            height: u32,
            block_hash: [32]u8,
            spent_external: []const root.Outpoint,
            undo_entries: []const root.UndoEntry,
            transactions: []const tx.Transaction,
            txids: []const [32]u8,
            spent: *std.AutoHashMap(root.Outpoint, void),
            new_utxo_count: i64,
        ) !root.CommitTimings {
            _ = self;
            _ = allocator;
            _ = height;
            _ = block_hash;
            _ = spent_external;
            _ = undo_entries;
            _ = transactions;
            _ = txids;
            _ = spent;
            _ = new_utxo_count;
            return .{};
        }
    };
}

pub fn testBlockValidity(allocator: std.mem.Allocator, store: anytype, raw: []const u8, height: u32, utxo_count: i64) !void {
    const parsed = try parseTemplate(allocator, raw);
    defer parsed.deinit(allocator);
    try checkTemplateLimits(allocator, parsed.transactions);
    const Store = @TypeOf(store.*);
    var wrapper = DiscardingStore(Store){ .inner = store };
    _ = try root.connectDecodedBlock(allocator, &wrapper, height, height, parsed.info, parsed.transactions, null, utxo_count);
}

const Candidate = struct {
    wtxid: [32]u8,
    fee: u64,
    weight: u64,
    sigops: u32,
};

pub fn selectPackages(comptime Store: type, allocator: std.mem.Allocator, pool: *mempool.Pool(Store), coinbase_weight: u64, coinbase_sigops: u32) ![][32]u8 {
    var remaining_weight: u64 = if (coinbase_weight >= MAX_BLOCK_WEIGHT) 0 else MAX_BLOCK_WEIGHT - coinbase_weight;
    var remaining_sigops: u32 = if (coinbase_sigops >= MAX_SIGOP_COST) 0 else MAX_SIGOP_COST - coinbase_sigops;
    var chosen = std.AutoHashMap([32]u8, void).init(allocator);
    defer chosen.deinit();
    var skipped = std.AutoHashMap([32]u8, void).init(allocator);
    defer skipped.deinit();
    var order: std.ArrayList([32]u8) = .empty;
    errdefer order.deinit(allocator);

    while (true) {
        var best: ?Candidate = null;
        var it = pool.iterator();
        while (it.next()) |entry| {
            if (chosen.contains(entry.key_ptr.*) or skipped.contains(entry.key_ptr.*)) continue;
            var fee: u64 = entry.value_ptr.fee;
            var weight: u64 = entry.value_ptr.weight;
            var sigops: u32 = entry.value_ptr.sigops;
            var missing_ancestor = false;
            for (entry.value_ptr.ancestors) |ancestor| {
                if (chosen.contains(ancestor)) continue;
                const parent = pool.get(ancestor) orelse {
                    missing_ancestor = true;
                    break;
                };
                fee +|= parent.fee;
                weight +|= parent.weight;
                sigops +|= parent.sigops;
            }
            if (missing_ancestor) continue;
            if (weight > remaining_weight or sigops > remaining_sigops) continue;
            const candidate = Candidate{ .wtxid = entry.key_ptr.*, .fee = fee, .weight = weight, .sigops = sigops };
            if (best == null or packageBetter(candidate, best.?)) best = candidate;
        }
        const winner = best orelse break;
        const winner_entry = pool.get(winner.wtxid) orelse break;
        var pending: std.ArrayList([32]u8) = .empty;
        defer pending.deinit(allocator);
        for (winner_entry.ancestors) |ancestor| {
            if (!chosen.contains(ancestor)) try pending.append(allocator, ancestor);
        }
        try pending.append(allocator, winner.wtxid);
        // Ancestors before the child: stable insertion by walking until parents are placed.
        var placed = try allocator.alloc(bool, pending.items.len);
        defer allocator.free(placed);
        @memset(placed, false);
        var guard: usize = 0;
        while (guard < pending.items.len * pending.items.len + 1) : (guard += 1) {
            var progress = false;
            for (pending.items, 0..) |wtxid, i| {
                if (placed[i]) continue;
                const item = pool.get(wtxid) orelse continue;
                var ready = true;
                for (item.ancestors) |ancestor| {
                    if (!chosen.contains(ancestor) and !sliceContains(pending.items, placed, ancestor)) {
                        // ancestor is in this package and not yet placed
                        var in_package = false;
                        for (pending.items, 0..) |other, j| {
                            if (placed[j]) continue;
                            if (std.mem.eql(u8, &other, &ancestor)) in_package = true;
                        }
                        if (in_package) ready = false;
                    }
                }
                if (!ready) continue;
                try chosen.put(wtxid, {});
                try order.append(allocator, wtxid);
                const added = pool.get(wtxid).?;
                remaining_weight -= added.weight;
                remaining_sigops -= added.sigops;
                placed[i] = true;
                progress = true;
            }
            if (!progress) {
                try skipped.put(winner.wtxid, {});
                break;
            }
            var done = true;
            for (placed) |flag| {
                if (!flag) done = false;
            }
            if (done) break;
        }
        var finished = true;
        for (placed) |flag| {
            if (!flag) finished = false;
        }
        if (!finished) try skipped.put(winner.wtxid, {});
    }
    return order.toOwnedSlice(allocator);
}

fn sliceContains(items: []const [32]u8, placed: []const bool, needle: [32]u8) bool {
    for (items, 0..) |item, i| {
        if (placed[i] and std.mem.eql(u8, &item, &needle)) return true;
    }
    return false;
}

fn packageBetter(a: Candidate, b: Candidate) bool {
    if (a.weight == 0) return false;
    if (b.weight == 0) return true;
    const left = @as(u128, a.fee) * b.weight;
    const right = @as(u128, b.fee) * a.weight;
    if (left > right) return true;
    if (left < right) return false;
    return std.mem.order(u8, &a.wtxid, &b.wtxid) == .lt;
}

fn compactTargetLe(bits: u32) ![32]u8 {
    const exponent: usize = @intCast(bits >> 24);
    const mantissa = bits & 0x007f_ffff;
    if ((bits & 0x0080_0000) != 0 or mantissa == 0) return error.InvalidCompactTarget;
    var target = [_]u8{0} ** 32;
    const mantissa_bytes = [_]u8{
        @intCast((mantissa >> 16) & 0xff),
        @intCast((mantissa >> 8) & 0xff),
        @intCast(mantissa & 0xff),
    };
    if (exponent <= 3) {
        var value = mantissa >> @intCast(8 * (3 - exponent));
        var index: usize = 0;
        while (value > 0 and index < 32) : (index += 1) {
            target[index] = @intCast(value & 0xff);
            value >>= 8;
        }
    } else {
        const start = exponent - 3;
        if (start + 3 > 32) return error.TargetOverflow;
        target[start] = mantissa_bytes[2];
        target[start + 1] = mantissa_bytes[1];
        target[start + 2] = mantissa_bytes[0];
    }
    return target;
}

fn compactFromTarget(target: [32]u8) u32 {
    var n_size: usize = 32;
    while (n_size > 0 and target[n_size - 1] == 0) n_size -= 1;
    var compact: u32 = 0;
    if (n_size <= 3) {
        var low: u32 = 0;
        var i: usize = 0;
        while (i < n_size) : (i += 1) low |= @as(u32, target[i]) << @intCast(8 * i);
        if (n_size < 3) compact = low << @intCast(8 * (3 - n_size));
        if (n_size == 3) compact = low;
        if (n_size == 0) compact = 0;
    } else {
        const start = n_size - 3;
        compact = @as(u32, target[start]) | (@as(u32, target[start + 1]) << 8) | (@as(u32, target[start + 2]) << 16);
    }
    if ((compact & 0x00800000) != 0) {
        compact >>= 8;
        n_size += 1;
    }
    compact |= @as(u32, @intCast(n_size)) << 24;
    return compact;
}

fn mulDiv256(target: [32]u8, numer: u64, denom: u64) [32]u8 {
    var product = [_]u8{0} ** 48;
    var carry: u128 = 0;
    for (target, 0..) |byte, i| {
        const wide = @as(u128, byte) * numer + carry;
        product[i] = @truncate(wide);
        carry = wide >> 8;
    }
    var extra: usize = 32;
    while (carry > 0 and extra < product.len) : (extra += 1) {
        product[extra] = @truncate(carry);
        carry >>= 8;
    }
    var rem: u128 = 0;
    var out = [_]u8{0} ** 48;
    var j: usize = product.len;
    while (j > 0) {
        j -= 1;
        rem = (rem << 8) | product[j];
        out[j] = @intCast(rem / denom);
        rem %= denom;
    }
    return out[0..32].*;
}

fn greaterLe(left: [32]u8, right: [32]u8) bool {
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (left[i] > right[i]) return true;
        if (left[i] < right[i]) return false;
    }
    return false;
}
