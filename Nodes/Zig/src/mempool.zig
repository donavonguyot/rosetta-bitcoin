const std = @import("std");
const root = @import("root.zig");
const coins_view = @import("coins_view.zig");
const consensus_context = @import("consensus_context.zig");
const tx = root.tx;
const script = root.script;
const store = root.store;

pub const Reason = enum {
    accepted,
    coinbase,
    input_spent_in_pool,
    input_spent_on_chain,
    missing_input,
    locktime_unsatisfied,
    sequence_unsatisfied,
    script_failed,

    pub fn name(self: Reason) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .coinbase => "coinbase",
            .input_spent_in_pool => "input_spent_in_pool",
            .input_spent_on_chain => "input_spent_on_chain",
            .missing_input => "missing_input",
            .locktime_unsatisfied => "locktime_unsatisfied",
            .sequence_unsatisfied => "sequence_unsatisfied",
            .script_failed => "script_failed",
        };
    }
};

pub const Verdict = struct {
    reason: Reason,
};

pub const Entry = struct {
    raw: []u8,
    txid: [32]u8,
    wtxid: [32]u8,
    fee: u64,
    weight: u64,
    sigops: u32,
    ancestors: [][32]u8,
};

pub fn Pool(comptime Store: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        coins: coins_view.Coins(Store),
        entries: std.AutoHashMap([32]u8, Entry),
        by_txid: std.AutoHashMap([32]u8, [32]u8),
        set_hash: store.SetHash = store.emptySetHash(),
        next_height: u32,
        tip_mtp: u32,

        pub fn init(allocator: std.mem.Allocator, backend: *Store, next_height: u32, tip_mtp: u32) Self {
            return .{
                .allocator = allocator,
                .coins = coins_view.Coins(Store).init(allocator, backend),
                .entries = std.AutoHashMap([32]u8, Entry).init(allocator),
                .by_txid = std.AutoHashMap([32]u8, [32]u8).init(allocator),
                .next_height = next_height,
                .tip_mtp = tip_mtp,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.raw);
                self.allocator.free(entry.value_ptr.ancestors);
            }
            self.entries.deinit();
            self.by_txid.deinit();
            self.coins.deinit();
        }

        pub fn setHashHex(self: *Self) [64]u8 {
            return store.writeSetHashHex(self.set_hash);
        }

        pub fn count(self: *Self) usize {
            return self.entries.count();
        }

        /// Re-adding evicted transactions after a disconnect is tip-lane work.
        pub fn restoreAfterDisconnect(self: *Self) error{DisconnectReplayNotImplemented}!void {
            _ = self;
            return error.DisconnectReplayNotImplemented;
        }

        pub fn check(self: *Self, raw: []const u8) !Verdict {
            const parsed = tx.deserialize(self.allocator, raw, 0) catch return .{ .reason = .script_failed };
            defer parsed.transaction.deinit(self.allocator);
            if (parsed.offset != raw.len) return .{ .reason = .script_failed };
            return self.checkParsed(parsed.transaction);
        }

        pub fn apply(self: *Self, raw: []const u8) !Verdict {
            const parsed = tx.deserialize(self.allocator, raw, 0) catch return .{ .reason = .script_failed };
            defer parsed.transaction.deinit(self.allocator);
            if (parsed.offset != raw.len) return .{ .reason = .script_failed };
            const verdict = try self.checkParsed(parsed.transaction);
            if (verdict.reason != .accepted) return verdict;
            try self.commit(raw, parsed.transaction);
            return verdict;
        }

        fn checkParsed(self: *Self, transaction: tx.Transaction) !Verdict {
            if (transaction.isCoinbase()) return .{ .reason = .coinbase };
            if (transaction.inputs.len == 0) return .{ .reason = .missing_input };

            var coins = try self.allocator.alloc(?coins_view.Coin, transaction.inputs.len);
            defer {
                for (coins) |coin| if (coin) |owned| if (owned.owned_script) self.allocator.free(owned.script);
                self.allocator.free(coins);
            }
            for (coins) |*slot| slot.* = null;

            for (transaction.inputs, 0..) |input, i| {
                const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                const found = try self.coins.lookup(outpoint);
                switch (found.kind) {
                    .spent_in_pool => return .{ .reason = .input_spent_in_pool },
                    .spent_on_chain => return .{ .reason = .input_spent_on_chain },
                    .missing => return .{ .reason = .missing_input },
                    .coin => {},
                }
                const coin = found.coin orelse return .{ .reason = .missing_input };
                coins[i] = coin;
            }

            if (locktimeUnsatisfied(transaction, self.next_height, self.tip_mtp)) return .{ .reason = .locktime_unsatisfied };

            for (transaction.inputs, coins) |input, coin_opt| {
                const coin = coin_opt orelse return .{ .reason = .missing_input };
                if (try sequenceUnsatisfied(&self.coins, transaction, input.sequence, coin, self.next_height, self.tip_mtp)) {
                    return .{ .reason = .sequence_unsatisfied };
                }
            }

            var in_value: u128 = 0;
            var out_value: u128 = 0;
            var prevouts = try self.allocator.alloc(script.SpentPrevout, transaction.inputs.len);
            defer self.allocator.free(prevouts);
            for (coins, 0..) |coin_opt, i| {
                const coin = coin_opt orelse return .{ .reason = .missing_input };
                in_value += coin.value;
                prevouts[i] = .{ .amount = @intCast(coin.value), .script_pubkey = coin.script };
            }
            for (transaction.outputs) |output| {
                if (output.value < 0) return .{ .reason = .script_failed };
                out_value += @intCast(output.value);
            }
            if (out_value > in_value) return .{ .reason = .script_failed };

            for (transaction.inputs, 0..) |_, i| {
                script.verifyInput(self.allocator, transaction, i, prevouts) catch return .{ .reason = .script_failed };
            }
            return .{ .reason = .accepted };
        }

        fn commit(self: *Self, raw: []const u8, transaction: tx.Transaction) !void {
            const wtxid = try transaction.wtxid(self.allocator);
            const txid = transaction.txid();
            var ancestors = std.AutoHashMap([32]u8, void).init(self.allocator);
            defer ancestors.deinit();
            var in_value: u128 = 0;
            for (transaction.inputs) |input| {
                const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                const found = try self.coins.lookup(outpoint);
                defer if (found.coin) |coin| if (coin.owned_script) self.allocator.free(coin.script);
                const coin = found.coin orelse return error.MissingInput;
                in_value += coin.value;
                if (coin.from_pool) {
                    if (self.by_txid.get(outpoint.txid)) |parent_wtxid| {
                        try ancestors.put(parent_wtxid, {});
                        if (self.entries.get(parent_wtxid)) |parent| {
                            for (parent.ancestors) |older| try ancestors.put(older, {});
                        }
                    }
                }
            }
            var out_value: u128 = 0;
            for (transaction.outputs) |output| out_value += @intCast(output.value);
            const fee: u64 = @intCast(in_value - out_value);
            const weight = try transactionWeight(self.allocator, transaction);
            var prevouts = try self.allocator.alloc([]const u8, transaction.inputs.len);
            defer self.allocator.free(prevouts);
            var owned_scripts = try self.allocator.alloc([]const u8, transaction.inputs.len);
            defer {
                for (owned_scripts) |bytes| self.allocator.free(bytes);
                self.allocator.free(owned_scripts);
            }
            for (owned_scripts) |*slot| slot.* = &.{};
            for (transaction.inputs, 0..) |input, i| {
                const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                const found = try self.coins.lookup(outpoint);
                const coin = found.coin orelse return error.MissingInput;
                if (coin.owned_script) {
                    owned_scripts[i] = coin.script;
                    prevouts[i] = coin.script;
                } else {
                    const copy = try self.allocator.dupe(u8, coin.script);
                    owned_scripts[i] = copy;
                    prevouts[i] = copy;
                }
            }
            const sigops = sigopCost(transaction, prevouts);

            var ancestor_list = try self.allocator.alloc([32]u8, ancestors.count());
            errdefer self.allocator.free(ancestor_list);
            var index: usize = 0;
            var ait = ancestors.keyIterator();
            while (ait.next()) |key| {
                ancestor_list[index] = key.*;
                index += 1;
            }
            const owned_raw = try self.allocator.dupe(u8, raw);
            errdefer self.allocator.free(owned_raw);
            try self.entries.put(wtxid, .{
                .raw = owned_raw,
                .txid = txid,
                .wtxid = wtxid,
                .fee = fee,
                .weight = weight,
                .sigops = sigops,
                .ancestors = ancestor_list,
            });
            try self.by_txid.put(txid, wtxid);
            store.foldSetHash(&self.set_hash, &wtxid, "");

            for (transaction.inputs) |input| {
                const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                try self.coins.markPoolSpend(outpoint);
            }
            for (transaction.outputs, 0..) |output, vout| {
                if (output.value < 0) return error.NegativeOutputValue;
                const outpoint = root.Outpoint{ .txid = txid, .vout = @intCast(vout) };
                try self.coins.addPoolOutput(outpoint, @intCast(output.value), self.next_height, false, output.script_pubkey);
            }
        }

        pub fn onBlockConnected(self: *Self, transactions: []const tx.Transaction, txids: []const [32]u8) !void {
            var confirmed = std.AutoHashMap([32]u8, void).init(self.allocator);
            defer confirmed.deinit();
            var block_spends = std.AutoHashMap(root.Outpoint, void).init(self.allocator);
            defer block_spends.deinit();
            for (transactions, txids) |transaction, txid| {
                try confirmed.put(txid, {});
                if (transaction.isCoinbase()) continue;
                for (transaction.inputs) |input| {
                    const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                    try block_spends.put(outpoint, {});
                    try self.coins.markChainSpend(outpoint);
                }
            }

            var dropped_txids = std.AutoHashMap([32]u8, void).init(self.allocator);
            defer dropped_txids.deinit();
            var drop = std.AutoHashMap([32]u8, void).init(self.allocator);
            defer drop.deinit();

            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (confirmed.contains(entry.value_ptr.txid)) {
                    try drop.put(entry.value_ptr.wtxid, {});
                    try dropped_txids.put(entry.value_ptr.txid, {});
                    continue;
                }
                const parsed = try tx.deserialize(self.allocator, entry.value_ptr.raw, 0);
                defer parsed.transaction.deinit(self.allocator);
                for (parsed.transaction.inputs) |input| {
                    const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                    if (block_spends.contains(outpoint)) {
                        try drop.put(entry.value_ptr.wtxid, {});
                        try dropped_txids.put(entry.value_ptr.txid, {});
                        break;
                    }
                }
            }

            var grew = true;
            while (grew) {
                grew = false;
                var scan = self.entries.iterator();
                while (scan.next()) |entry| {
                    if (drop.contains(entry.value_ptr.wtxid)) continue;
                    const parsed = try tx.deserialize(self.allocator, entry.value_ptr.raw, 0);
                    defer parsed.transaction.deinit(self.allocator);
                    for (parsed.transaction.inputs) |input| {
                        if (dropped_txids.contains(input.previous_output.hash)) {
                            try drop.put(entry.value_ptr.wtxid, {});
                            try dropped_txids.put(entry.value_ptr.txid, {});
                            grew = true;
                            break;
                        }
                    }
                }
            }

            var drop_it = drop.keyIterator();
            while (drop_it.next()) |wtxid| try self.remove(wtxid.*);
        }

        fn remove(self: *Self, wtxid: [32]u8) !void {
            const entry = self.entries.fetchRemove(wtxid) orelse return;
            defer {
                self.allocator.free(entry.value.raw);
                self.allocator.free(entry.value.ancestors);
            }
            _ = self.by_txid.remove(entry.value.txid);
            store.foldSetHash(&self.set_hash, &wtxid, "");
            const parsed = try tx.deserialize(self.allocator, entry.value.raw, 0);
            defer parsed.transaction.deinit(self.allocator);
            for (parsed.transaction.inputs) |input| {
                const outpoint = root.Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
                self.coins.unmarkPoolSpend(outpoint);
            }
            for (parsed.transaction.outputs, 0..) |_, vout| {
                const outpoint = root.Outpoint{ .txid = entry.value.txid, .vout = @intCast(vout) };
                self.coins.removePoolOutput(outpoint);
            }
        }

        pub fn iterator(self: *Self) std.AutoHashMap([32]u8, Entry).Iterator {
            return self.entries.iterator();
        }

        pub fn get(self: *Self, wtxid: [32]u8) ?Entry {
            return self.entries.get(wtxid);
        }
    };
}

pub fn transactionWeight(allocator: std.mem.Allocator, transaction: tx.Transaction) !u64 {
    const stripped = try tx.serialize(allocator, transaction, false);
    defer allocator.free(stripped);
    const full = try tx.serialize(allocator, transaction, true);
    defer allocator.free(full);
    return @as(u64, stripped.len) * 3 + @as(u64, full.len);
}

pub fn sigopCost(transaction: tx.Transaction, prev_scripts: []const []const u8) u32 {
    var cost: u32 = 0;
    for (transaction.inputs) |input| cost += legacySigops(input.script_sig) * 4;
    for (transaction.outputs) |output| cost += legacySigops(output.script_pubkey) * 4;
    for (transaction.inputs, 0..) |input, i| {
        const prev = if (i < prev_scripts.len) prev_scripts[i] else &.{};
        const witness = if (i < transaction.witness.len) transaction.witness[i] else &.{};
        cost += witnessSigopCost(prev, input.script_sig, witness);
    }
    return cost;
}

fn locktimeUnsatisfied(transaction: tx.Transaction, next_height: u32, mtp: u32) bool {
    return consensus_context.txNotFinal(transaction, next_height, mtp, mtp);
}

fn sequenceUnsatisfied(coins: anytype, transaction: tx.Transaction, sequence: u32, coin: coins_view.Coin, next_height: u32, mtp: u32) !bool {
    // A pool output is created at `next_height`, so its confirmation MTP is the
    // tip MTP passed in here. A chain output reads the header index only when
    // this input is a relative time lock.
    const coin_time: u32 = if (!consensus_context.sequenceNeedsCoinTime(transaction.version, sequence, next_height))
        0
    else if (coin.from_pool)
        mtp
    else
        try coins.medianTimePast(if (coin.height == 0) 0 else coin.height - 1);
    return consensus_context.sequenceLockUnsatisfied(transaction.version, sequence, coin.height, coin_time, next_height, mtp);
}

fn legacySigops(bytes: []const u8) u32 {
    var i: usize = 0;
    var count: u32 = 0;
    while (i < bytes.len) {
        const op = bytes[i];
        i += 1;
        if (op > 0 and op < 0x4c) {
            if (i + op > bytes.len) break;
            i += op;
            continue;
        }
        if (op == 0x4c) {
            if (i >= bytes.len) break;
            const n = bytes[i];
            i += 1;
            if (i + n > bytes.len) break;
            i += n;
            continue;
        }
        if (op == 0x4d) {
            if (i + 2 > bytes.len) break;
            const n = std.mem.readInt(u16, bytes[i..][0..2], .little);
            i += 2;
            if (i + n > bytes.len) break;
            i += n;
            continue;
        }
        if (op == 0x4e) {
            if (i + 4 > bytes.len) break;
            const n = std.mem.readInt(u32, bytes[i..][0..4], .little);
            i += 4;
            if (@as(u64, i) + n > bytes.len) break;
            i += n;
            continue;
        }
        if (op == 0xac or op == 0xad or op == 0xba) count += 1;
        if (op == 0xae or op == 0xaf) count += 20;
    }
    return count;
}

fn witnessSigopCost(script_pubkey: []const u8, script_sig: []const u8, witness: []const []const u8) u32 {
    if (script_pubkey.len == 22 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x14) return 1;
    if (script_pubkey.len == 34 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x20) {
        if (witness.len == 0) return 0;
        return legacySigops(witness[witness.len - 1]);
    }
    if (script_pubkey.len == 23 and script_pubkey[0] == 0xa9 and script_pubkey[1] == 0x14 and script_pubkey[22] == 0x87) {
        const redeem = lastPush(script_sig) orelse return 0;
        if (redeem.len == 22 and redeem[0] == 0x00 and redeem[1] == 0x14) return 1;
        if (redeem.len == 34 and redeem[0] == 0x00 and redeem[1] == 0x20) {
            if (witness.len == 0) return 0;
            return legacySigops(witness[witness.len - 1]);
        }
        return legacySigops(redeem) * 4;
    }
    return 0;
}

fn lastPush(script_sig: []const u8) ?[]const u8 {
    var i: usize = 0;
    var last: ?[]const u8 = null;
    while (i < script_sig.len) {
        const op = script_sig[i];
        i += 1;
        if (op > 0 and op < 0x4c) {
            if (i + op > script_sig.len) return last;
            last = script_sig[i .. i + op];
            i += op;
            continue;
        }
        if (op == 0x4c) {
            if (i >= script_sig.len) return last;
            const n = script_sig[i];
            i += 1;
            if (i + n > script_sig.len) return last;
            last = script_sig[i .. i + n];
            i += n;
            continue;
        }
        last = null;
    }
    return last;
}
