const std = @import("std");
const root = @import("root.zig");
const consensus_context = @import("consensus_context.zig");

pub const LookupKind = enum { coin, spent_in_pool, spent_on_chain, missing };

pub const Coin = struct {
    value: u64,
    height: u32,
    coinbase: bool,
    /// Median time past of the block before the confirmation block. Left at 0;
    /// a time lock reads it from the header index when the input needs it.
    confirmation_mtp: u32,
    script: []const u8,
    from_pool: bool,
    /// True when `script` was allocated for this lookup and the caller must free it.
    owned_script: bool,
};

pub fn Coins(comptime Store: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        store: *Store,
        pool_out: std.AutoHashMap(root.Outpoint, PoolCoin),
        pool_spent: std.AutoHashMap(root.Outpoint, void),
        chain_spent: std.AutoHashMap(root.Outpoint, void),

        const PoolCoin = struct {
            value: u64,
            height: u32,
            coinbase: bool,
            script: []u8,
        };

        pub fn init(allocator: std.mem.Allocator, store: *Store) Self {
            return .{
                .allocator = allocator,
                .store = store,
                .pool_out = std.AutoHashMap(root.Outpoint, PoolCoin).init(allocator),
                .pool_spent = std.AutoHashMap(root.Outpoint, void).init(allocator),
                .chain_spent = std.AutoHashMap(root.Outpoint, void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.pool_out.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.script);
            self.pool_out.deinit();
            self.pool_spent.deinit();
            self.chain_spent.deinit();
        }

        pub fn addPoolOutput(self: *Self, outpoint: root.Outpoint, value: u64, height: u32, coinbase: bool, script: []const u8) !void {
            const owned = try self.allocator.dupe(u8, script);
            errdefer self.allocator.free(owned);
            if (self.pool_out.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script);
            try self.pool_out.put(outpoint, .{ .value = value, .height = height, .coinbase = coinbase, .script = owned });
        }

        pub fn markPoolSpend(self: *Self, outpoint: root.Outpoint) !void {
            try self.pool_spent.put(outpoint, {});
        }

        pub fn unmarkPoolSpend(self: *Self, outpoint: root.Outpoint) void {
            _ = self.pool_spent.remove(outpoint);
        }

        pub fn removePoolOutput(self: *Self, outpoint: root.Outpoint) void {
            if (self.pool_out.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script);
        }

        pub fn markChainSpend(self: *Self, outpoint: root.Outpoint) !void {
            try self.chain_spent.put(outpoint, {});
            self.removePoolOutput(outpoint);
        }

        pub fn headerAt(self: *Self, height: u32) !?[80]u8 {
            return self.store.headerAt(self.allocator, height);
        }

        pub fn medianTimePast(self: *Self, height: u32) !u32 {
            try self.store.ensureHeaderIndex();
            return self.store.medianTimePast(height);
        }

        pub fn lookup(self: *Self, outpoint: root.Outpoint) !struct { kind: LookupKind, coin: ?Coin } {
            if (self.pool_spent.contains(outpoint)) return .{ .kind = .spent_in_pool, .coin = null };
            if (self.chain_spent.contains(outpoint)) return .{ .kind = .spent_on_chain, .coin = null };
            if (self.pool_out.get(outpoint)) |pool| {
                return .{
                    .kind = .coin,
                    .coin = .{
                        .value = pool.value,
                        .height = pool.height,
                        .coinbase = pool.coinbase,
                        .confirmation_mtp = 0,
                        .script = pool.script,
                        .from_pool = true,
                        .owned_script = false,
                    },
                };
            }
            var one = [_]root.Outpoint{outpoint};
            const loaded = try self.store.getManyUtxosWithStats(self.allocator, "testnet4", one[0..], null);
            defer self.allocator.free(loaded);
            const utxo = loaded[0] orelse return .{ .kind = .missing, .coin = null };
            return .{
                .kind = .coin,
                .coin = .{
                    .value = utxo.value_sats,
                    .height = utxo.height,
                    .coinbase = utxo.coinbase,
                    .confirmation_mtp = 0,
                    .script = utxo.script_pubkey,
                    .from_pool = false,
                    .owned_script = true,
                },
            };
        }
    };
}

/// In-memory store for mechanism tests. `commitConnectedBlock` counts calls and writes nothing.
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    utxos: std.AutoHashMap(root.Outpoint, root.StoredUtxo),
    headers: std.AutoHashMap(u32, [80]u8),
    header_index: consensus_context.HeaderIndex = .{},
    commits: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{
            .allocator = allocator,
            .utxos = std.AutoHashMap(root.Outpoint, root.StoredUtxo).init(allocator),
            .headers = std.AutoHashMap(u32, [80]u8).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.utxos.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.script_pubkey);
        self.utxos.deinit();
        self.headers.deinit();
        self.header_index.deinit(self.allocator);
    }

    pub fn putUtxo(self: *MemoryStore, outpoint: root.Outpoint, utxo: root.StoredUtxo) !void {
        const script = try self.allocator.dupe(u8, utxo.script_pubkey);
        errdefer self.allocator.free(script);
        var owned = utxo;
        owned.script_pubkey = script;
        if (self.utxos.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script_pubkey);
        try self.utxos.put(outpoint, owned);
    }

    pub fn putHeader(self: *MemoryStore, height: u32, header: [80]u8) !void {
        try self.headers.put(height, header);
        try self.header_index.set(self.allocator, height, consensus_context.fieldsFromHeader(&header));
    }

    pub fn ensureHeaderIndex(_: *MemoryStore) !void {}

    pub fn headerIndex(self: *MemoryStore) consensus_context.HeaderIndex {
        return self.header_index;
    }

    pub fn medianTimePast(self: *MemoryStore, height: u32) !u32 {
        return self.header_index.mtp(height);
    }

    pub fn headerFields(self: *MemoryStore, height: u32) !?consensus_context.HeaderFields {
        return self.header_index.fields(height);
    }

    pub fn headerAt(self: *MemoryStore, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
        _ = allocator;
        return self.headers.get(height);
    }

    pub fn getManyUtxosWithStats(self: *MemoryStore, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const root.Outpoint, stats: ?*root.UtxoLoadStats) ![]?root.StoredUtxo {
        _ = chain;
        const out = try allocator.alloc(?root.StoredUtxo, outpoints.len);
        errdefer allocator.free(out);
        for (outpoints, 0..) |outpoint, i| {
            if (self.utxos.get(outpoint)) |utxo| {
                if (stats) |s| s.utxo_hit_count += 1;
                out[i] = .{
                    .height = utxo.height,
                    .vout = utxo.vout,
                    .value_sats = utxo.value_sats,
                    .coinbase = utxo.coinbase,
                    .script_pubkey = try allocator.dupe(u8, utxo.script_pubkey),
                };
            } else {
                if (stats) |s| s.utxo_miss_count += 1;
                out[i] = null;
            }
        }
        return out;
    }

    pub fn commitConnectedBlock(self: *MemoryStore, allocator: std.mem.Allocator, height: u32, block_hash: [32]u8, spent_external: []const root.Outpoint, undo_entries: []const root.UndoEntry, transactions: []const root.tx.Transaction, txids: []const [32]u8, spent: *std.AutoHashMap(root.Outpoint, void), new_utxo_count: i64) !root.CommitTimings {
        _ = allocator;
        _ = height;
        _ = block_hash;
        _ = spent_external;
        _ = undo_entries;
        _ = transactions;
        _ = txids;
        _ = spent;
        _ = new_utxo_count;
        self.commits += 1;
        return .{};
    }
};
