//! Layer-1 coin lookup over a chainstate plus the in-pool UTXO overlay (BIP68 needs the coin height).
//! A pool spend hides the chain coin, and a pool output is visible before it is in the store.
//! Does not apply relay policy. That is layer 2 and is not a pass/fail (`MEMPOOL_CONTRACT`).

const std = @import("std");
const root = @import("root.zig");
const consensus_context = @import("consensus_context.zig");

/// Whether a coin came from the pool, the chain, or was missing.
/// Lookup sees a pool output before a chain coin, and never a spent pool input.
/// test "in-pool spend is accepted and a second spend is rejected"
pub const LookupKind = enum { coin, spent_in_pool, spent_on_chain, missing };

/// A UTXO the mempool can see: value, script, height, and whether it is still in the pool.
/// Lookup sees a pool output before a chain coin, and never a spent pool input.
/// test "in-pool spend is accepted and a second spend is rejected"
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

/// Chainstate plus the in-pool overlay used by layer-1 checks.
/// Lookup sees a pool output before a chain coin, and never a spent pool input.
/// test "in-pool spend is accepted and a second spend is rejected"
pub fn Coins(comptime Store: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        store: *Store,
        pool_out: std.AutoHashMap(root.types.Outpoint, PoolCoin),
        pool_spent: std.AutoHashMap(root.types.Outpoint, void),
        chain_spent: std.AutoHashMap(root.types.Outpoint, void),

        const PoolCoin = struct {
            value: u64,
            height: u32,
            coinbase: bool,
            script: []u8,
        };

        /// Build an empty value the caller frees with deinit.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn init(allocator: std.mem.Allocator, store: *Store) Self {
            return .{
                .allocator = allocator,
                .store = store,
                .pool_out = std.AutoHashMap(root.types.Outpoint, PoolCoin).init(allocator),
                .pool_spent = std.AutoHashMap(root.types.Outpoint, void).init(allocator),
                .chain_spent = std.AutoHashMap(root.types.Outpoint, void).init(allocator),
            };
        }

        /// Free the bytes this value owns. The caller does not free them again.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn deinit(self: *Self) void {
            var it = self.pool_out.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.script);
            self.pool_out.deinit();
            self.pool_spent.deinit();
            self.chain_spent.deinit();
        }

        /// Publish a pool output so a later in-pool child can spend it.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn addPoolOutput(self: *Self, outpoint: root.types.Outpoint, value: u64, height: u32, coinbase: bool, script: []const u8) !void {
            const owned = try self.allocator.dupe(u8, script);
            errdefer self.allocator.free(owned);
            if (self.pool_out.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script);
            try self.pool_out.put(outpoint, .{ .value = value, .height = height, .coinbase = coinbase, .script = owned });
        }

        /// Hide a chain or pool coin behind an in-pool spend.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn markPoolSpend(self: *Self, outpoint: root.types.Outpoint) !void {
            try self.pool_spent.put(outpoint, {});
        }

        /// Undo an in-pool spend marker when the spending transaction leaves the pool.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn unmarkPoolSpend(self: *Self, outpoint: root.types.Outpoint) void {
            _ = self.pool_spent.remove(outpoint);
        }

        /// Drop a pool output that left the pool without being mined.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn removePoolOutput(self: *Self, outpoint: root.types.Outpoint) void {
            if (self.pool_out.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script);
        }

        /// Remember that a connected block spent this outpoint so a later replay cannot.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn markChainSpend(self: *Self, outpoint: root.types.Outpoint) !void {
            try self.chain_spent.put(outpoint, {});
            self.removePoolOutput(outpoint);
        }

        /// The 80-byte header at a height, or null past the stored tip.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn headerAt(self: *Self, height: u32) !?[80]u8 {
            return self.store.headerAt(self.allocator, height);
        }

        /// Median of up to 11 header timestamps ending at a height. BIP113 and the template use it.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn medianTimePast(self: *Self, height: u32) !u32 {
            try self.store.ensureHeaderIndex();
            return self.store.medianTimePast(height);
        }

        /// Resolve one outpoint through the pool overlay, then the chain.
        /// Lookup sees a pool output before a chain coin, and never a spent pool input.
        /// test "in-pool spend is accepted and a second spend is rejected"
        pub fn lookup(self: *Self, outpoint: root.types.Outpoint) !struct { kind: LookupKind, coin: ?Coin } {
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
            var one = [_]root.types.Outpoint{outpoint};
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
/// test "in-pool spend is accepted and a second spend is rejected"
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    utxos: std.AutoHashMap(root.types.Outpoint, root.types.StoredUtxo),
    headers: std.AutoHashMap(u32, [80]u8),
    header_index: consensus_context.HeaderIndex = .{},
    commits: usize = 0,
    tip_hash: ?[32]u8 = null,

    /// Build an empty value the caller frees with deinit.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{
            .allocator = allocator,
            .utxos = std.AutoHashMap(root.types.Outpoint, root.types.StoredUtxo).init(allocator),
            .headers = std.AutoHashMap(u32, [80]u8).init(allocator),
        };
    }

    /// Free the bytes this value owns. The caller does not free them again.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn deinit(self: *MemoryStore) void {
        var it = self.utxos.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.script_pubkey);
        self.utxos.deinit();
        self.headers.deinit();
        self.header_index.deinit(self.allocator);
    }

    /// Store one UTXO for mechanism tests.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn putUtxo(self: *MemoryStore, outpoint: root.types.Outpoint, utxo: root.types.StoredUtxo) !void {
        const script = try self.allocator.dupe(u8, utxo.script_pubkey);
        errdefer self.allocator.free(script);
        var owned = utxo;
        owned.script_pubkey = script;
        if (self.utxos.fetchRemove(outpoint)) |old| self.allocator.free(old.value.script_pubkey);
        try self.utxos.put(outpoint, owned);
    }

    /// Store an 80-byte header for mechanism tests.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn putHeader(self: *MemoryStore, height: u32, header: [80]u8) !void {
        try self.headers.put(height, header);
        try self.header_index.set(self.allocator, height, consensus_context.fieldsFromHeader(&header));
    }

    /// Make header time and bits readable. Native open already loaded them.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn ensureHeaderIndex(_: *MemoryStore) !void {}

    /// The dense header index connect and the mempool use for MTP.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn headerIndex(self: *MemoryStore) consensus_context.HeaderIndex {
        return self.header_index;
    }

    /// Median of up to 11 header timestamps ending at a height. BIP113 and the template use it.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn medianTimePast(self: *MemoryStore, height: u32) !u32 {
        return self.header_index.mtp(height);
    }

    /// Indexed time and nBits at a height, or null when that height is not stored.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn headerFields(self: *MemoryStore, height: u32) !?consensus_context.HeaderFields {
        return self.header_index.fields(height);
    }

    /// Internal hash of the last connected block, or null before genesis.
    /// Connect compares a candidate's prev_hash to this and does not apply a competing parent.
    /// test "parent mismatch rejects a block whose prev is not the tip"
    pub fn tipHash(self: *MemoryStore) !?[32]u8 {
        return self.tip_hash;
    }

    /// The 80-byte header at a height, or null past the stored tip.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn headerAt(self: *MemoryStore, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
        _ = allocator;
        return self.headers.get(height);
    }

    /// Decoded UTXOs plus hit and miss timing for the lookups connect actually issued.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn getManyUtxosWithStats(self: *MemoryStore, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const root.types.Outpoint, stats: ?*root.connect.UtxoLoadStats) ![]?root.types.StoredUtxo {
        _ = chain;
        const out = try allocator.alloc(?root.types.StoredUtxo, outpoints.len);
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

    /// Apply the spends and creates from a block that connect has already checked.
    /// Lookup sees a pool output before a chain coin, and never a spent pool input.
    /// test "in-pool spend is accepted and a second spend is rejected"
    pub fn commitConnectedBlock(self: *MemoryStore, allocator: std.mem.Allocator, height: u32, block_hash: [32]u8, spent_external: []const root.types.Outpoint, undo_entries: []const root.types.UndoEntry, transactions: []const root.tx.Transaction, txids: []const [32]u8, spent: *std.AutoHashMap(root.types.Outpoint, void), new_utxo_count: i64) !root.connect.CommitTimings {
        _ = allocator;
        _ = height;
        _ = spent_external;
        _ = undo_entries;
        _ = transactions;
        _ = txids;
        _ = spent;
        _ = new_utxo_count;
        self.tip_hash = block_hash;
        self.commits += 1;
        return .{};
    }
};
