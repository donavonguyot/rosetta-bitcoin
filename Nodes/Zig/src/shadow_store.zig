const std = @import("std");
const types = @import("types.zig");
const codec = @import("codec.zig");
const store = @import("store.zig");
const connect = @import("connect.zig");
const consensus_context = @import("consensus_context.zig");
const tx = @import("tx.zig");

const elapsedMs = connect.elapsedMs;
const CommitTimings = connect.CommitTimings;
const UtxoLoadStats = connect.UtxoLoadStats;
const Outpoint = types.Outpoint;
const UndoEntry = types.UndoEntry;
const StoredUtxo = types.StoredUtxo;
const decodeUtxoValue = codec.decodeUtxoValue;
const Metadata = types.Metadata;
const ChainstateBlockCommit = types.ChainstateBlockCommit;

pub fn ShadowStore(comptime Primary: type, comptime Shadow: type) type {
    return struct {
        primary: *Primary,
        shadow: *Shadow,
        primary_utxo_load_ms: i64 = 0,
        shadow_utxo_load_ms: i64 = 0,
        primary_commit_ms: i64 = 0,
        shadow_commit_ms: i64 = 0,
        primary_set_hash_fold_ms: i64 = 0,
        shadow_set_hash_fold_ms: i64 = 0,
        primary_snapshot_ms: i64 = 0,
        shadow_snapshot_ms: i64 = 0,
        primary_record_block_ms: i64 = 0,
        shadow_record_block_ms: i64 = 0,
        divergence_count: u64 = 0,

        const Self = @This();

        pub fn init(primary: *Primary, shadow: *Shadow) Self {
            return .{ .primary = primary, .shadow = shadow };
        }

        pub fn setHash(self: *Self) store.SetHash {
            return self.primary.setHash();
        }

        pub fn headerAt(self: *Self, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
            return self.primary.headerAt(allocator, height);
        }

        pub fn ensureHeaderIndex(self: *Self) !void {
            try self.primary.ensureHeaderIndex();
            try self.shadow.ensureHeaderIndex();
        }

        pub fn headerIndex(self: *Self) consensus_context.HeaderIndex {
            return self.primary.headerIndex();
        }

        pub fn medianTimePast(self: *Self, height: u32) !u32 {
            return self.primary.medianTimePast(height);
        }

        pub fn headerFields(self: *Self, height: u32) !?consensus_context.HeaderFields {
            return self.primary.headerFields(height);
        }

        pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
            try self.primary.put(key, value);
            try self.shadow.put(key, value);
        }

        pub fn getAlloc(self: *Self, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
            const primary_value = try self.primary.getAlloc(allocator, key);
            const shadow_value = try self.shadow.getAlloc(allocator, key);
            defer if (shadow_value) |bytes| allocator.free(bytes);
            if (!store.rawEqual(primary_value, shadow_value)) {
                if (primary_value) |bytes| allocator.free(bytes);
                return self.fail("get", 0);
            }
            return primary_value;
        }

        pub fn getManyUtxoRaw(self: *Self, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const Outpoint, stats: ?*UtxoLoadStats) ![]?[]u8 {
            const started = store.nowMs();
            const primary_raw = try self.primary.getManyUtxoRaw(allocator, chain, outpoints, stats);
            self.primary_utxo_load_ms += elapsedMs(started);
            errdefer freeRaw(allocator, primary_raw);
            const shadow_started = store.nowMs();
            const shadow_raw = try self.shadow.getManyUtxoRaw(allocator, chain, outpoints, null);
            self.shadow_utxo_load_ms += elapsedMs(shadow_started);
            defer freeRaw(allocator, shadow_raw);
            for (primary_raw, shadow_raw, 0..) |primary_value, shadow_value, index| {
                if (!store.rawEqual(primary_value, shadow_value)) return self.fail("get_many", index);
            }
            return primary_raw;
        }

        pub fn getManyUtxosWithStats(self: *Self, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const Outpoint, stats: ?*UtxoLoadStats) ![]?StoredUtxo {
            const raw = try self.getManyUtxoRaw(allocator, chain, outpoints, stats);
            defer freeRaw(allocator, raw);
            const out = try allocator.alloc(?StoredUtxo, outpoints.len);
            var decoded: usize = 0;
            errdefer {
                for (out[0..decoded]) |value| if (value) |utxo| utxo.deinit(allocator);
                allocator.free(out);
            }
            for (outpoints, raw, 0..) |outpoint, value, i| {
                out[i] = if (value) |bytes| try decodeUtxoValue(allocator, outpoint, bytes) else null;
                decoded += 1;
            }
            return out;
        }

        pub fn recordBlock(self: *Self, allocator: std.mem.Allocator, height: u32, hash: [32]u8, raw: []const u8) !void {
            const started = store.nowMs();
            try self.primary.recordBlock(allocator, height, hash, raw);
            self.primary_record_block_ms += elapsedMs(started);
            const shadow_started = store.nowMs();
            try self.shadow.recordBlock(allocator, height, hash, raw);
            self.shadow_record_block_ms += elapsedMs(shadow_started);
        }

        pub fn commitBlock(self: *Self, allocator: std.mem.Allocator, commit: ChainstateBlockCommit) !CommitTimings {
            return self.commitBoth(allocator, commit, null);
        }

        pub fn commitConnectedBlock(
            self: *Self,
            allocator: std.mem.Allocator,
            height: u32,
            block_hash: [32]u8,
            spent_external: []const Outpoint,
            undo_entries: []const UndoEntry,
            transactions: []const tx.Transaction,
            txids: []const [32]u8,
            spent: *std.AutoHashMap(Outpoint, void),
            new_utxo_count: i64,
        ) !CommitTimings {
            const started = store.nowMs();
            const primary_timings = try self.primary.commitConnectedBlock(allocator, height, block_hash, spent_external, undo_entries, transactions, txids, spent, new_utxo_count);
            self.notePrimaryCommit(primary_timings, elapsedMs(started));
            const shadow_started = store.nowMs();
            const shadow_timings = try self.shadow.commitConnectedBlock(allocator, height, block_hash, spent_external, undo_entries, transactions, txids, spent, new_utxo_count);
            self.noteShadowCommit(shadow_timings, elapsedMs(shadow_started));
            try self.expectTip();
            return primary_timings;
        }

        pub fn readMetadata(self: *Self, allocator: std.mem.Allocator) !Metadata {
            const primary_meta = try self.primary.readMetadata(allocator);
            const shadow_meta = try self.shadow.readMetadata(allocator);
            defer self.shadow.deinitMetadata(allocator, shadow_meta);
            if (primary_meta.validated_height != shadow_meta.validated_height or
                primary_meta.chainstate_utxo_count != shadow_meta.chainstate_utxo_count or
                !std.mem.eql(u8, primary_meta.validated_hash, shadow_meta.validated_hash) or
                !std.mem.eql(u8, primary_meta.chainstate_set_hash, shadow_meta.chainstate_set_hash))
            {
                self.primary.deinitMetadata(allocator, primary_meta);
                return self.fail("read_metadata", 0);
            }
            return primary_meta;
        }

        pub fn deinitMetadata(self: *Self, allocator: std.mem.Allocator, meta: Metadata) void {
            self.primary.deinitMetadata(allocator, meta);
        }

        fn commitBoth(self: *Self, allocator: std.mem.Allocator, commit: ChainstateBlockCommit, _: ?void) !CommitTimings {
            const started = store.nowMs();
            const primary_timings = try self.primary.commitBlock(allocator, commit);
            self.notePrimaryCommit(primary_timings, elapsedMs(started));
            const shadow_started = store.nowMs();
            const shadow_timings = try self.shadow.commitBlock(allocator, commit);
            self.noteShadowCommit(shadow_timings, elapsedMs(shadow_started));
            try self.expectTip();
            return primary_timings;
        }

        fn notePrimaryCommit(self: *Self, timings: CommitTimings, elapsed: i64) void {
            self.primary_commit_ms += if (timings.snapshot > elapsed) 0 else elapsed - timings.snapshot;
            self.primary_snapshot_ms += timings.snapshot;
            self.primary_set_hash_fold_ms += timings.set_hash_fold;
        }

        fn noteShadowCommit(self: *Self, timings: CommitTimings, elapsed: i64) void {
            self.shadow_commit_ms += if (timings.snapshot > elapsed) 0 else elapsed - timings.snapshot;
            self.shadow_snapshot_ms += timings.snapshot;
            self.shadow_set_hash_fold_ms += timings.set_hash_fold;
        }

        fn expectTip(self: *Self) !void {
            const primary_hash = self.primary.setHash();
            const shadow_hash = self.shadow.setHash();
            if (!std.mem.eql(u8, &primary_hash, &shadow_hash) or
                self.primary.utxo_count != self.shadow.utxo_count or
                self.primary.validated_height != self.shadow.validated_height)
            {
                return self.fail("commit", 0);
            }
        }

        fn fail(self: *Self, op: []const u8, index: usize) error{StoreDivergence} {
            self.divergence_count += 1;
            const primary_hash = store.writeSetHashHex(self.primary.setHash());
            const shadow_hash = store.writeSetHashHex(self.shadow.setHash());
            std.debug.print(
                "{{\"schema\":\"port.native_store.divergence.v1\",\"op\":\"{s}\",\"index\":{},\"primary_height\":{},\"shadow_height\":{},\"primary_utxo_count\":{},\"shadow_utxo_count\":{},\"primary_set_hash\":\"{s}\",\"shadow_set_hash\":\"{s}\"}}\n",
                .{ op, index, self.primary.validated_height, self.shadow.validated_height, self.primary.utxo_count, self.shadow.utxo_count, primary_hash[0..], shadow_hash[0..] },
            );
            return error.StoreDivergence;
        }
    };
}

fn freeRaw(allocator: std.mem.Allocator, values: []?[]u8) void {
    for (values) |value| if (value) |bytes| allocator.free(bytes);
    allocator.free(values);
}
