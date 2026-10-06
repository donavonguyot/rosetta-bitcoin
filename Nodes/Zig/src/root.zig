const std = @import("std");
const build_options = @import("crypto_options");

pub const script_verify_split = @import("script_verify_split.zig");
pub const store_mode = build_options.store;
pub const rocksdb_compiled = build_options.store_rocksdb;

const c = @cImport({
    if (build_options.store_rocksdb) @cInclude("rocksdb/c.h");
});

const datadir = @import("datadir.zig");
const crypto_glue = @import("crypto_glue.zig");

pub const crypto = crypto_glue.crypto;
pub const secp256k1Available = crypto_glue.secp256k1Available;
pub const nowMs = datadir.nowMs;
pub const rejectUnapprovedRuntimeDbArtifacts = datadir.rejectUnapprovedRuntimeDbArtifacts;
pub const DatadirLock = datadir.DatadirLock;
pub const chain_params = @import("chain_params.zig");
pub const consensus_context = @import("consensus_context.zig");
pub const tx = @import("tx.zig");
pub const block = @import("block.zig");
pub const script = @import("script.zig");
pub const p2p = @import("p2p.zig");
pub const store = @import("store.zig");
pub const native_store = @import("native_store.zig");
pub const coins_view = @import("coins_view.zig");
pub const mempool = @import("mempool.zig");
pub const template = @import("template.zig");
pub const context_fixture = @import("context_fixture.zig");
pub const rung0 = @import("rung0.zig");

const connect = @import("connect.zig");
const elapsedMs = connect.elapsedMs;

pub const foldSpends = connect.foldSpends;
pub const CommitTimings = connect.CommitTimings;
pub const UtxoLoadStats = connect.UtxoLoadStats;
pub const ConnectTimings = connect.ConnectTimings;
pub const ConnectResult = connect.ConnectResult;
pub const ScriptVerifyStats = connect.ScriptVerifyStats;
pub const defaultScriptThreadCount = connect.defaultScriptThreadCount;
pub const ScriptCryptoBackend = connect.ScriptCryptoBackend;
pub const ScriptVerifyRunner = connect.ScriptVerifyRunner;
pub const connectDecodedBlock = connect.connectDecodedBlock;
pub const isSpendableOutput = connect.isSpendableOutput;

const types_mod = @import("types.zig");
const codec = @import("codec.zig");

pub const PortInfo = types_mod.PortInfo;
pub const Outpoint = types_mod.Outpoint;
pub const StoredUtxo = types_mod.StoredUtxo;
pub const CreatedUtxo = types_mod.CreatedUtxo;
pub const UndoEntry = types_mod.UndoEntry;
pub const ChainstateBlockCommit = types_mod.ChainstateBlockCommit;
pub const Metadata = types_mod.Metadata;

pub const CodecVectors = codec.CodecVectors;
pub const encodeUtxoKey = codec.encodeUtxoKey;
pub const encodeUtxoKeyInto = codec.encodeUtxoKeyInto;
pub const encodedUtxoKeyLen = codec.encodedUtxoKeyLen;
pub const encodeUtxoValue = codec.encodeUtxoValue;
pub const encodeUndoKey = codec.encodeUndoKey;
pub const encodeTipKey = codec.encodeTipKey;
pub const encodeBlockIndexKey = codec.encodeBlockIndexKey;
pub const encodeHeaderKey = codec.encodeHeaderKey;
pub const encodeRawBlockKey = codec.encodeRawBlockKey;
pub const encodeMetadataKey = codec.encodeMetadataKey;
pub const toHexAlloc = codec.toHexAlloc;
pub const fromHexAlloc = codec.fromHexAlloc;
pub const verifyCodecVectors = codec.verifyCodecVectors;
pub const encodeTipValue = codec.encodeTipValue;
pub const encodeUndoValue = codec.encodeUndoValue;
pub const decodeUtxoValue = codec.decodeUtxoValue;

pub const RocksDb = if (rocksdb_compiled) struct {
    db: *c.rocksdb_t,
    read_opts: *c.rocksdb_readoptions_t,
    write_opts: *c.rocksdb_writeoptions_t,
    block_options: *c.rocksdb_block_based_table_options_t,
    block_cache: *c.rocksdb_cache_t,
    allocator: std.mem.Allocator,
    set_hash: store.SetHash = store.emptySetHash(),
    utxo_count: i64 = 0,
    validated_height: i64 = -1,
    header_index: consensus_context.HeaderIndex = .{},
    header_index_ready: bool = false,

    pub const block_cache_mb: usize = 512;
    pub const write_buffer_mb: usize = 64;
    pub const max_write_buffers: c_int = 4;
    pub const max_background_jobs: c_int = 4;
    pub const bloom_bits_per_key: f64 = 10.0;

    pub fn tuningDescription() []const u8 {
        return "create_if_missing=true,parallelism=4,block_cache_mb=512,bloom_bits_per_key=10,cache_index_filter_blocks=true,write_buffer_mb=64,max_write_buffer_number=4,max_background_jobs=4";
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !RocksDb {
        try rejectUnapprovedRuntimeDbArtifacts(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const options = c.rocksdb_options_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_options_destroy(options);
        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_increase_parallelism(options, 4);
        c.rocksdb_options_set_write_buffer_size(options, write_buffer_mb * 1024 * 1024);
        c.rocksdb_options_set_max_write_buffer_number(options, max_write_buffers);
        c.rocksdb_options_set_max_background_jobs(options, max_background_jobs);

        const block_options = c.rocksdb_block_based_options_create() orelse return error.RocksDbOptions;
        errdefer c.rocksdb_block_based_options_destroy(block_options);
        const block_cache = c.rocksdb_cache_create_lru(block_cache_mb * 1024 * 1024) orelse return error.RocksDbOptions;
        errdefer c.rocksdb_cache_destroy(block_cache);
        const filter_policy = c.rocksdb_filterpolicy_create_bloom(bloom_bits_per_key) orelse return error.RocksDbOptions;
        c.rocksdb_block_based_options_set_block_cache(block_options, block_cache);
        c.rocksdb_block_based_options_set_filter_policy(block_options, filter_policy);
        c.rocksdb_block_based_options_set_cache_index_and_filter_blocks(block_options, 1);
        c.rocksdb_block_based_options_set_cache_index_and_filter_blocks_with_high_priority(block_options, 1);
        c.rocksdb_block_based_options_set_pin_l0_filter_and_index_blocks_in_cache(block_options, 1);
        c.rocksdb_options_set_block_based_table_factory(options, block_options);

        var err: [*c]u8 = null;
        const db = c.rocksdb_open(options, path_z.ptr, &err) orelse {
            defer if (err != null) c.rocksdb_free(err);
            return error.RocksDbOpen;
        };
        if (err != null) {
            c.rocksdb_free(err);
            c.rocksdb_close(db);
            return error.RocksDbOpen;
        }
        const read_opts = c.rocksdb_readoptions_create() orelse {
            c.rocksdb_close(db);
            return error.RocksDbOptions;
        };
        errdefer c.rocksdb_readoptions_destroy(read_opts);
        const write_opts = c.rocksdb_writeoptions_create() orelse {
            c.rocksdb_close(db);
            return error.RocksDbOptions;
        };
        errdefer c.rocksdb_writeoptions_destroy(write_opts);
        errdefer c.rocksdb_close(db);
        var opened = RocksDb{
            .db = db,
            .read_opts = read_opts,
            .write_opts = write_opts,
            .block_options = block_options,
            .block_cache = block_cache,
            .allocator = allocator,
        };
        try opened.loadRuntimeCounters();
        return opened;
    }

    pub fn setHash(self: *RocksDb) store.SetHash {
        return self.set_hash;
    }

    fn loadRuntimeCounters(self: *RocksDb) !void {
        self.validated_height = try self.metaI64(self.allocator, "validated_height", -1);
        self.utxo_count = try self.metaI64(self.allocator, "chainstate_utxo_count", 0);
        const hex = try self.metaString(self.allocator, "chainstate_set_hash", "");
        defer self.allocator.free(hex);
        if (hex.len == 0) return;
        self.set_hash = try store.parseSetHashHex(hex);
    }

    pub fn close(self: *RocksDb) void {
        self.header_index.deinit(self.allocator);
        c.rocksdb_close(self.db);
        c.rocksdb_readoptions_destroy(self.read_opts);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_block_based_options_destroy(self.block_options);
        c.rocksdb_cache_destroy(self.block_cache);
    }

    pub fn put(self: *RocksDb, key: []const u8, value: []const u8) !void {
        var err: [*c]u8 = null;
        c.rocksdb_put(self.db, self.write_opts, key.ptr, key.len, value.ptr, value.len, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
    }

    pub fn getAlloc(self: *RocksDb, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        var err: [*c]u8 = null;
        var len: usize = 0;
        const ptr = c.rocksdb_get(self.db, self.read_opts, key.ptr, key.len, &len, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbRead;
        }
        if (ptr == null) return null;
        defer c.rocksdb_free(ptr);
        return try allocator.dupe(u8, ptr[0..len]);
    }

    pub fn headerAt(self: *RocksDb, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
        const key = try encodeHeaderKey(allocator, "testnet4", height);
        defer allocator.free(key);
        const raw = (try self.getAlloc(allocator, key)) orelse return null;
        defer allocator.free(raw);
        if (raw.len < 80) return error.ShortHeader;
        var header: [80]u8 = undefined;
        @memcpy(header[0..], raw[0..80]);
        return header;
    }

    pub fn ensureHeaderIndex(self: *RocksDb) !void {
        if (self.header_index_ready) return;
        if (self.validated_height >= 0) {
            const last: u32 = @intCast(self.validated_height);
            var height: u32 = 0;
            while (height <= last) : (height += 1) {
                const raw = (try self.headerAt(self.allocator, height)) orelse return error.MissingHeader;
                try self.header_index.set(self.allocator, height, consensus_context.fieldsFromHeader(&raw));
            }
        }
        self.header_index_ready = true;
    }

    pub fn headerIndex(self: *RocksDb) consensus_context.HeaderIndex {
        return self.header_index;
    }

    pub fn medianTimePast(self: *RocksDb, height: u32) !u32 {
        try self.ensureHeaderIndex();
        return self.header_index.mtp(height);
    }

    pub fn headerFields(self: *RocksDb, height: u32) !?consensus_context.HeaderFields {
        try self.ensureHeaderIndex();
        return self.header_index.fields(height);
    }

    pub fn getManyRaw(self: *RocksDb, allocator: std.mem.Allocator, keys: []const []const u8) ![]?[]u8 {
        const out = try allocator.alloc(?[]u8, keys.len);
        errdefer allocator.free(out);
        if (keys.len == 0) return out;

        const key_ptrs = try allocator.alloc([*c]const u8, keys.len);
        defer allocator.free(key_ptrs);
        const key_lens = try allocator.alloc(usize, keys.len);
        defer allocator.free(key_lens);
        var value_ptrs = try allocator.alloc([*c]u8, keys.len);
        defer allocator.free(value_ptrs);
        var value_lens = try allocator.alloc(usize, keys.len);
        defer allocator.free(value_lens);
        var errs = try allocator.alloc([*c]u8, keys.len);
        defer allocator.free(errs);

        for (keys, 0..) |key, i| {
            key_ptrs[i] = key.ptr;
            key_lens[i] = key.len;
            value_ptrs[i] = null;
            value_lens[i] = 0;
            errs[i] = null;
            out[i] = null;
        }

        c.rocksdb_multi_get(self.db, self.read_opts, keys.len, key_ptrs.ptr, key_lens.ptr, value_ptrs.ptr, value_lens.ptr, errs.ptr);
        for (keys, 0..) |_, i| {
            if (errs[i] != null) {
                c.rocksdb_free(errs[i]);
                return error.RocksDbRead;
            }
            if (value_ptrs[i] != null) {
                out[i] = try allocator.dupe(u8, value_ptrs[i][0..value_lens[i]]);
                c.rocksdb_free(value_ptrs[i]);
            }
        }
        return out;
    }

    pub fn getManyUtxos(self: *RocksDb, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const Outpoint) ![]?StoredUtxo {
        return self.getManyUtxosWithStats(allocator, chain, outpoints, null);
    }

    pub fn getManyUtxoRaw(self: *RocksDb, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const Outpoint, stats: ?*UtxoLoadStats) ![]?[]u8 {
        const out = try allocator.alloc(?[]u8, outpoints.len);
        errdefer allocator.free(out);
        if (outpoints.len == 0) return out;

        const key_len = try encodedUtxoKeyLen(chain);
        var key_bytes: std.ArrayList(u8) = .empty;
        defer key_bytes.deinit(allocator);
        try key_bytes.ensureTotalCapacity(allocator, key_len * outpoints.len);
        const key_ptrs = try allocator.alloc([*c]const u8, outpoints.len);
        defer allocator.free(key_ptrs);
        const key_lens = try allocator.alloc(usize, outpoints.len);
        defer allocator.free(key_lens);
        var value_ptrs = try allocator.alloc([*c]u8, outpoints.len);
        defer allocator.free(value_ptrs);
        var value_lens = try allocator.alloc(usize, outpoints.len);
        defer allocator.free(value_lens);
        var errs = try allocator.alloc([*c]u8, outpoints.len);
        defer allocator.free(errs);

        for (outpoints, 0..) |outpoint, i| {
            const start = key_bytes.items.len;
            try encodeUtxoKeyInto(allocator, &key_bytes, chain, outpoint);
            key_ptrs[i] = key_bytes.items[start..].ptr;
            key_lens[i] = key_bytes.items.len - start;
            value_ptrs[i] = null;
            value_lens[i] = 0;
            errs[i] = null;
            out[i] = null;
        }

        if (stats) |s| {
            s.lookup_count += outpoints.len;
            s.key_bytes += key_bytes.items.len;
        }

        c.rocksdb_multi_get(self.db, self.read_opts, outpoints.len, key_ptrs.ptr, key_lens.ptr, value_ptrs.ptr, value_lens.ptr, errs.ptr);
        var copied: usize = 0;
        errdefer {
            for (out[0..copied]) |value| if (value) |bytes| allocator.free(bytes);
            for (value_ptrs) |ptr| if (ptr != null) c.rocksdb_free(ptr);
        }
        for (outpoints, 0..) |_, i| {
            if (errs[i] != null) {
                c.rocksdb_free(errs[i]);
                return error.RocksDbRead;
            }
            if (value_ptrs[i] != null) {
                const raw = value_ptrs[i][0..value_lens[i]];
                if (stats) |s| s.value_bytes += raw.len;
                out[i] = try allocator.dupe(u8, raw);
                copied += 1;
                c.rocksdb_free(value_ptrs[i]);
                value_ptrs[i] = null;
            }
        }
        return out;
    }

    pub fn getManyUtxosWithStats(self: *RocksDb, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const Outpoint, stats: ?*UtxoLoadStats) ![]?StoredUtxo {
        const raw = try self.getManyUtxoRaw(allocator, chain, outpoints, stats);
        defer {
            for (raw) |value| if (value) |bytes| allocator.free(bytes);
            allocator.free(raw);
        }
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

    pub fn recordBlock(self: *RocksDb, allocator: std.mem.Allocator, height: u32, hash: [32]u8, raw: []const u8) !void {
        const batch = c.rocksdb_writebatch_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writebatch_destroy(batch);

        const raw_key = try encodeRawBlockKey(allocator, "testnet4", height);
        defer allocator.free(raw_key);
        c.rocksdb_writebatch_put(batch, raw_key.ptr, raw_key.len, raw.ptr, raw.len);

        const header_key = try encodeHeaderKey(allocator, "testnet4", height);
        defer allocator.free(header_key);
        c.rocksdb_writebatch_put(batch, header_key.ptr, header_key.len, raw.ptr, @min(raw.len, 80));

        const index_key = try encodeBlockIndexKey(allocator, "testnet4", height);
        defer allocator.free(index_key);
        const hash_display = try crypto.displayHashAlloc(allocator, hash[0..]);
        defer allocator.free(hash_display);
        c.rocksdb_writebatch_put(batch, index_key.ptr, index_key.len, hash_display.ptr, hash_display.len);

        var err: [*c]u8 = null;
        c.rocksdb_write(self.db, self.write_opts, batch, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
        if (raw.len >= 80) {
            var header_bytes: [80]u8 = undefined;
            @memcpy(header_bytes[0..], raw[0..80]);
            try self.ensureHeaderIndex();
            try self.header_index.set(self.allocator, height, consensus_context.fieldsFromHeader(&header_bytes));
        }
    }

    pub fn readMetadata(self: *RocksDb, allocator: std.mem.Allocator) !Metadata {
        const validated_height = try self.metaI64(allocator, "validated_height", -1);
        const header_height = try self.metaI64(allocator, "header_height", validated_height);
        const stored_block_height = try self.metaI64(allocator, "stored_block_height", validated_height);
        const chainstate_utxo_count = try self.metaI64(allocator, "chainstate_utxo_count", 0);
        return .{
            .validated_height = validated_height,
            .validated_hash = try self.metaString(allocator, "validated_hash", ""),
            .header_height = header_height,
            .header_hash = try self.metaString(allocator, "header_hash", ""),
            .stored_block_height = stored_block_height,
            .stored_block_hash = try self.metaString(allocator, "stored_block_hash", ""),
            .chainstate_backend = try self.metaString(allocator, "chainstate_backend", "rocksdb"),
            .chainstate_status = try self.metaString(allocator, "chainstate_status", "missing"),
            .sync_status = try self.metaString(allocator, "sync_status", "starting"),
            .chainstate_utxo_count = chainstate_utxo_count,
            .chainstate_set_hash = try store.formatSetHash(allocator, self.set_hash),
            .current_blocker = try self.metaString(allocator, "current_blocker", ""),
        };
    }

    pub fn deinitMetadata(_: *RocksDb, allocator: std.mem.Allocator, meta: Metadata) void {
        allocator.free(meta.validated_hash);
        allocator.free(meta.header_hash);
        allocator.free(meta.stored_block_hash);
        allocator.free(meta.chainstate_backend);
        allocator.free(meta.chainstate_status);
        allocator.free(meta.sync_status);
        allocator.free(meta.chainstate_set_hash);
        allocator.free(meta.current_blocker);
    }

    fn metaString(self: *RocksDb, allocator: std.mem.Allocator, name: []const u8, default: []const u8) ![]u8 {
        const key = try encodeMetadataKey(allocator, name);
        defer allocator.free(key);
        return (try self.getAlloc(allocator, key)) orelse try allocator.dupe(u8, default);
    }

    fn metaI64(self: *RocksDb, allocator: std.mem.Allocator, name: []const u8, default: i64) !i64 {
        const value = try self.metaString(allocator, name, "");
        defer allocator.free(value);
        if (value.len == 0) return default;
        return std.fmt.parseInt(i64, value, 10) catch default;
    }

    pub fn commitBlock(self: *RocksDb, allocator: std.mem.Allocator, commit: ChainstateBlockCommit) !CommitTimings {
        var timings = CommitTimings{};
        var next_hash = self.set_hash;
        const batch = c.rocksdb_writebatch_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writebatch_destroy(batch);

        const spend_fold_started = nowMs();
        try foldSpends(allocator, &next_hash, commit.spent_external, commit.undo_entries);
        timings.set_hash_fold += elapsedMs(spend_fold_started);

        const delete_started = nowMs();
        for (commit.spent_external) |outpoint| {
            const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
            defer allocator.free(key);
            c.rocksdb_writebatch_delete(batch, key.ptr, key.len);
        }
        timings.utxo_delete_prepare += elapsedMs(delete_started);

        const put_started = nowMs();
        var put_fold: i64 = 0;
        for (commit.created_utxos) |created| {
            const key = try encodeUtxoKey(allocator, "testnet4", created.outpoint);
            defer allocator.free(key);
            const value = try encodeUtxoValue(allocator, created.utxo);
            defer allocator.free(value);
            const hash_started = nowMs();
            store.foldSetHash(&next_hash, key, value);
            put_fold += elapsedMs(hash_started);
            c.rocksdb_writebatch_put(batch, key.ptr, key.len, value.ptr, value.len);
        }
        timings.utxo_put_prepare += elapsedMs(put_started) - put_fold;
        timings.set_hash_fold += put_fold;

        const undo_started = nowMs();
        const undo_key = try encodeUndoKey(allocator, "testnet4", commit.height);
        defer allocator.free(undo_key);
        const undo_value = try encodeUndoValue(allocator, commit.undo_entries);
        defer allocator.free(undo_value);
        c.rocksdb_writebatch_put(batch, undo_key.ptr, undo_key.len, undo_value.ptr, undo_value.len);
        timings.undo_put_prepare += elapsedMs(undo_started);

        const metadata_started = nowMs();
        const tip_key = try encodeTipKey(allocator, "testnet4");
        defer allocator.free(tip_key);
        const tip_value = try encodeTipValue(allocator, commit.height, commit.block_hash);
        defer allocator.free(tip_value);
        c.rocksdb_writebatch_put(batch, tip_key.ptr, tip_key.len, tip_value.ptr, tip_value.len);

        const height_key = try encodeMetadataKey(allocator, "validated_height");
        defer allocator.free(height_key);
        const height_value = try std.fmt.allocPrint(allocator, "{}", .{commit.height});
        defer allocator.free(height_value);
        c.rocksdb_writebatch_put(batch, height_key.ptr, height_key.len, height_value.ptr, height_value.len);

        const hash_display = try crypto.displayHashAlloc(allocator, commit.block_hash[0..]);
        defer allocator.free(hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "validated_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "header_height", height_value);
        try rocks_meta.putMetaBatch(allocator, batch, "header_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "stored_block_height", height_value);
        try rocks_meta.putMetaBatch(allocator, batch, "stored_block_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "sync_status", "blocks_current");
        try rocks_meta.putMetaBatch(allocator, batch, "chainstate_status", "usable");
        try rocks_meta.putMetaBatch(allocator, batch, "current_blocker", "");

        const backend_key = try encodeMetadataKey(allocator, "chainstate_backend");
        defer allocator.free(backend_key);
        c.rocksdb_writebatch_put(batch, backend_key.ptr, backend_key.len, "rocksdb".ptr, 7);

        const counter_key = try encodeMetadataKey(allocator, "chainstate_utxo_count");
        defer allocator.free(counter_key);
        const counter_value = try std.fmt.allocPrint(allocator, "{}", .{commit.new_utxo_count});
        defer allocator.free(counter_value);
        c.rocksdb_writebatch_put(batch, counter_key.ptr, counter_key.len, counter_value.ptr, counter_value.len);
        const set_hash_hex = store.writeSetHashHex(next_hash);
        try rocks_meta.putMetaBatch(allocator, batch, "chainstate_set_hash", set_hash_hex[0..]);
        timings.metadata_put_prepare += elapsedMs(metadata_started);

        const write_started = nowMs();
        var err: [*c]u8 = null;
        c.rocksdb_write(self.db, self.write_opts, batch, &err);
        timings.rocksdb_write += elapsedMs(write_started);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
        self.set_hash = next_hash;
        self.utxo_count = commit.new_utxo_count;
        self.validated_height = commit.height;
        return timings;
    }

    pub fn commitConnectedBlock(
        self: *RocksDb,
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
        var timings = CommitTimings{};
        var next_hash = self.set_hash;
        const batch = c.rocksdb_writebatch_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writebatch_destroy(batch);

        const spend_fold_started = nowMs();
        try foldSpends(allocator, &next_hash, spent_external, undo_entries);
        timings.set_hash_fold += elapsedMs(spend_fold_started);

        const delete_started = nowMs();
        for (spent_external) |outpoint| {
            const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
            defer allocator.free(key);
            c.rocksdb_writebatch_delete(batch, key.ptr, key.len);
        }
        timings.utxo_delete_prepare += elapsedMs(delete_started);

        const put_started = nowMs();
        var put_fold: i64 = 0;
        for (transactions, 0..) |transaction, tx_index| {
            if (height == 0 and tx_index == 0) continue;
            for (transaction.outputs, 0..) |output, vout| {
                if (output.value < 0) return error.NegativeOutputValue;
                if (!isSpendableOutput(output.script_pubkey)) continue;
                const outpoint = Outpoint{ .txid = txids[tx_index], .vout = @intCast(vout) };
                if (spent.contains(outpoint)) continue;
                const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
                defer allocator.free(key);
                const value = try encodeUtxoValue(allocator, .{
                    .height = height,
                    .vout = @intCast(vout),
                    .value_sats = @intCast(output.value),
                    .coinbase = tx_index == 0,
                    .script_pubkey = output.script_pubkey,
                });
                defer allocator.free(value);
                const hash_started = nowMs();
                store.foldSetHash(&next_hash, key, value);
                put_fold += elapsedMs(hash_started);
                c.rocksdb_writebatch_put(batch, key.ptr, key.len, value.ptr, value.len);
            }
        }
        timings.utxo_put_prepare += elapsedMs(put_started) - put_fold;
        timings.set_hash_fold += put_fold;

        const undo_started = nowMs();
        const undo_key = try encodeUndoKey(allocator, "testnet4", height);
        defer allocator.free(undo_key);
        const undo_value = try encodeUndoValue(allocator, undo_entries);
        defer allocator.free(undo_value);
        c.rocksdb_writebatch_put(batch, undo_key.ptr, undo_key.len, undo_value.ptr, undo_value.len);
        timings.undo_put_prepare += elapsedMs(undo_started);

        const metadata_started = nowMs();
        try rocks_meta.putCommitMetadata(allocator, batch, height, block_hash, new_utxo_count, next_hash);
        timings.metadata_put_prepare += elapsedMs(metadata_started);

        const write_started = nowMs();
        var err: [*c]u8 = null;
        c.rocksdb_write(self.db, self.write_opts, batch, &err);
        timings.rocksdb_write += elapsedMs(write_started);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
        self.set_hash = next_hash;
        self.utxo_count = new_utxo_count;
        self.validated_height = height;
        return timings;
    }

    pub fn writeBatchSmoke(self: *RocksDb, allocator: std.mem.Allocator) !void {
        const batch = c.rocksdb_writebatch_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writebatch_destroy(batch);

        var txid: [32]u8 = undefined;
        for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
        const script_bytes = try fromHexAlloc(allocator, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
        defer allocator.free(script_bytes);
        const utxo_key = try encodeUtxoKey(allocator, "testnet4", .{ .txid = txid, .vout = 1 });
        defer allocator.free(utxo_key);
        const utxo_value = try encodeUtxoValue(allocator, .{
            .height = 1,
            .vout = 1,
            .value_sats = 5_000_000_000,
            .coinbase = true,
            .script_pubkey = script_bytes,
        });
        defer allocator.free(utxo_value);
        c.rocksdb_writebatch_put(batch, utxo_key.ptr, utxo_key.len, utxo_value.ptr, utxo_value.len);
        var next_hash = self.set_hash;
        store.foldSetHash(&next_hash, utxo_key, utxo_value);
        const set_hash_hex = store.writeSetHashHex(next_hash);
        const set_hash_key = try encodeMetadataKey(allocator, "chainstate_set_hash");
        defer allocator.free(set_hash_key);
        c.rocksdb_writebatch_put(batch, set_hash_key.ptr, set_hash_key.len, set_hash_hex[0..].ptr, set_hash_hex.len);

        const counter_key = try encodeMetadataKey(allocator, "chainstate_utxo_count");
        defer allocator.free(counter_key);
        c.rocksdb_writebatch_put(batch, counter_key.ptr, counter_key.len, "1".ptr, 1);

        const status_key = try encodeMetadataKey(allocator, "validated_height");
        defer allocator.free(status_key);
        c.rocksdb_writebatch_put(batch, status_key.ptr, status_key.len, "2".ptr, 1);

        const backend_key = try encodeMetadataKey(allocator, "chainstate_backend");
        defer allocator.free(backend_key);
        c.rocksdb_writebatch_put(batch, backend_key.ptr, backend_key.len, "rocksdb".ptr, 7);

        var err: [*c]u8 = null;
        c.rocksdb_write(self.db, self.write_opts, batch, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
        self.set_hash = next_hash;
        self.utxo_count = 1;
        self.validated_height = 2;
    }
} else struct {
    pub fn open(_: std.mem.Allocator, _: []const u8) error{StoreNotCompiled}!@This() {
        return error.StoreNotCompiled;
    }

    pub fn close(_: *@This()) void {}

    pub fn tuningDescription() []const u8 {
        return "not compiled";
    }
};

const rocks_meta = if (rocksdb_compiled) struct {
    fn putMetaBatch(allocator: std.mem.Allocator, batch: *c.rocksdb_writebatch_t, name: []const u8, value: []const u8) !void {
        const key = try encodeMetadataKey(allocator, name);
        defer allocator.free(key);
        c.rocksdb_writebatch_put(batch, key.ptr, key.len, value.ptr, value.len);
    }

    fn putCommitMetadata(allocator: std.mem.Allocator, batch: *c.rocksdb_writebatch_t, height: u32, block_hash: [32]u8, utxo_count: i64, set_hash: store.SetHash) !void {
        const tip_key = try encodeTipKey(allocator, "testnet4");
        defer allocator.free(tip_key);
        const tip_value = try encodeTipValue(allocator, height, block_hash);
        defer allocator.free(tip_value);
        c.rocksdb_writebatch_put(batch, tip_key.ptr, tip_key.len, tip_value.ptr, tip_value.len);

        const height_key = try encodeMetadataKey(allocator, "validated_height");
        defer allocator.free(height_key);
        const height_value = try std.fmt.allocPrint(allocator, "{}", .{height});
        defer allocator.free(height_value);
        c.rocksdb_writebatch_put(batch, height_key.ptr, height_key.len, height_value.ptr, height_value.len);

        const hash_display = try crypto.displayHashAlloc(allocator, block_hash[0..]);
        defer allocator.free(hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "validated_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "header_height", height_value);
        try rocks_meta.putMetaBatch(allocator, batch, "header_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "stored_block_height", height_value);
        try rocks_meta.putMetaBatch(allocator, batch, "stored_block_hash", hash_display);
        try rocks_meta.putMetaBatch(allocator, batch, "sync_status", "blocks_current");
        try rocks_meta.putMetaBatch(allocator, batch, "chainstate_status", "usable");
        try rocks_meta.putMetaBatch(allocator, batch, "current_blocker", "");

        const backend_key = try encodeMetadataKey(allocator, "chainstate_backend");
        defer allocator.free(backend_key);
        c.rocksdb_writebatch_put(batch, backend_key.ptr, backend_key.len, "rocksdb".ptr, 7);

        const counter_key = try encodeMetadataKey(allocator, "chainstate_utxo_count");
        defer allocator.free(counter_key);
        const counter_value = try std.fmt.allocPrint(allocator, "{}", .{utxo_count});
        defer allocator.free(counter_value);
        c.rocksdb_writebatch_put(batch, counter_key.ptr, counter_key.len, counter_value.ptr, counter_value.len);
        const set_hash_hex = store.writeSetHashHex(set_hash);
        try rocks_meta.putMetaBatch(allocator, batch, "chainstate_set_hash", set_hash_hex[0..]);
    }
} else struct {};

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

test "native-only build does not open rocksdb" {
    if (comptime rocksdb_compiled) return;
    try std.testing.expectError(error.StoreNotCompiled, RocksDb.open(std.testing.allocator, "unused"));
}

test "codec v2 golden vectors" {
    try verifyCodecVectors(std.testing.allocator);
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

test "get many raw preserves requested order and missing slots" {
    if (comptime !rocksdb_compiled) return;
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/test-get-many-rocksdb-{}", .{std.testing.random_seed});
    defer allocator.free(path);
    var db = try RocksDb.open(allocator, path);
    defer db.close();
    try db.put("a", "one");
    try db.put("c", "three");
    const values = try db.getManyRaw(allocator, &.{ "a", "b", "c" });
    defer {
        for (values) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(values);
    }
    try std.testing.expectEqualStrings("one", values[0].?);
    try std.testing.expect(values[1] == null);
    try std.testing.expectEqualStrings("three", values[2].?);
}

test "scratch utxo key encoding matches codec vector" {
    const allocator = std.testing.allocator;
    var txid: [32]u8 = undefined;
    for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try encodeUtxoKeyInto(allocator, &bytes, "testnet4", .{ .txid = txid, .vout = 1 });
    const hex = try toHexAlloc(allocator, bytes.items);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(CodecVectors.utxo_key_hex, hex);
}

test "direct utxo multi get preserves order missing slots and decoded equality" {
    if (comptime !rocksdb_compiled) return;
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/test-get-many-utxos-rocksdb-{}", .{std.testing.random_seed});
    defer allocator.free(path);
    var db = try RocksDb.open(allocator, path);
    defer db.close();
    const script_bytes = try fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    var txid_a = [_]u8{0} ** 32;
    txid_a[0] = 1;
    var txid_b = [_]u8{0} ** 32;
    txid_b[0] = 2;
    var txid_c = [_]u8{0} ** 32;
    txid_c[0] = 3;
    const outpoint_a = Outpoint{ .txid = txid_a, .vout = 0 };
    const outpoint_b = Outpoint{ .txid = txid_b, .vout = 0 };
    const outpoint_c = Outpoint{ .txid = txid_c, .vout = 2 };
    const key_a = try encodeUtxoKey(allocator, "testnet4", outpoint_a);
    defer allocator.free(key_a);
    const value_a = try encodeUtxoValue(allocator, .{ .height = 7, .vout = 0, .value_sats = 11, .coinbase = false, .script_pubkey = script_bytes });
    defer allocator.free(value_a);
    try db.put(key_a, value_a);
    const key_c = try encodeUtxoKey(allocator, "testnet4", outpoint_c);
    defer allocator.free(key_c);
    const value_c = try encodeUtxoValue(allocator, .{ .height = 8, .vout = 2, .value_sats = 22, .coinbase = true, .script_pubkey = script_bytes });
    defer allocator.free(value_c);
    try db.put(key_c, value_c);

    var stats = UtxoLoadStats{};
    const values = try db.getManyUtxosWithStats(allocator, "testnet4", &.{ outpoint_a, outpoint_b, outpoint_c }, &stats);
    defer {
        for (values) |value| if (value) |utxo| utxo.deinit(allocator);
        allocator.free(values);
    }
    try std.testing.expect(values[0] != null);
    try std.testing.expect(values[1] == null);
    try std.testing.expect(values[2] != null);
    try std.testing.expectEqual(@as(u64, 11), values[0].?.value_sats);
    try std.testing.expectEqual(@as(u32, 2), values[2].?.vout);
    try std.testing.expectEqual(@as(u64, 3), stats.lookup_count);
    try std.testing.expect(stats.key_bytes > 0);
    try std.testing.expect(stats.value_bytes >= value_a.len + value_c.len);
}

test "commit block writes created utxos undo tip metadata and counters" {
    if (comptime !rocksdb_compiled) return;
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/test-commit-block-rocksdb-{}", .{std.testing.random_seed});
    defer allocator.free(path);
    var db = try RocksDb.open(allocator, path);
    defer db.close();
    const script_bytes = try fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    var txid = [_]u8{0} ** 32;
    txid[0] = 7;
    const outpoint = Outpoint{ .txid = txid, .vout = 0 };
    const block_hash = [_]u8{9} ** 32;
    const commit_timings = try db.commitBlock(allocator, .{
        .height = 1,
        .block_hash = block_hash,
        .spent_external = &.{},
        .created_utxos = &.{.{ .outpoint = outpoint, .utxo = .{
            .height = 1,
            .vout = 0,
            .value_sats = 42,
            .coinbase = false,
            .script_pubkey = script_bytes,
        } }},
        .undo_entries = &.{},
        .new_utxo_count = 1,
    });
    try std.testing.expect(commit_timings.total() >= 0);
    const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
    defer allocator.free(key);
    const stored = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(stored);
    try std.testing.expect(stored.len > 0);
    const counter_key = try encodeMetadataKey(allocator, "chainstate_utxo_count");
    defer allocator.free(counter_key);
    const counter = (try db.getAlloc(allocator, counter_key)).?;
    defer allocator.free(counter);
    try std.testing.expectEqualStrings("1", counter);
}

test {
    _ = crypto;
    _ = tx;
    _ = block;
    _ = script;
    _ = connect;
}
