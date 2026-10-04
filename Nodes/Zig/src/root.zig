const std = @import("std");
const build_options = @import("crypto_options");

pub const script_verify_split = @import("script_verify_split.zig");
pub const store_mode = build_options.store;
pub const rocksdb_compiled = build_options.store_rocksdb;

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/time.h");
    @cInclude("time.h");
    if (build_options.store_rocksdb) @cInclude("rocksdb/c.h");
});

pub const crypto = @import("crypto.zig");
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
pub const rung0 = @import("rung0.zig");

pub const PortInfo = struct {
    pub const port_key = "zig";
    pub const binary_name = "zigbitnode";
    pub const display_name = "ZigNode";
    pub const default_datadir = "./data-zig";
    pub const marker_file = ".zigbitnode_native_storage";
    pub const lock_file = ".zigbitnode.lock";
    pub const rocksdb_dir = "chainstate-rocksdb";
    pub const rocksdb_shadow_dir = "chainstate-rocksdb-shadow";
    pub const native_dir = "chainstate-native";
};

pub const Outpoint = struct {
    txid: [32]u8,
    vout: u32,
};

pub const StoredUtxo = struct {
    height: u32,
    vout: u32,
    value_sats: u64,
    coinbase: bool,
    script_pubkey: []const u8,

    pub fn deinit(self: StoredUtxo, allocator: std.mem.Allocator) void {
        allocator.free(self.script_pubkey);
    }
};

pub const CreatedUtxo = struct {
    outpoint: Outpoint,
    utxo: StoredUtxo,
};

pub const UndoEntry = struct {
    outpoint: Outpoint,
    utxo: StoredUtxo,
};

pub const ChainstateBlockCommit = struct {
    height: u32,
    block_hash: [32]u8,
    spent_external: []const Outpoint,
    created_utxos: []const CreatedUtxo,
    undo_entries: []const UndoEntry,
    new_utxo_count: i64,
};

pub const Metadata = struct {
    validated_height: i64 = -1,
    validated_hash: []const u8 = "",
    header_height: i64 = -1,
    header_hash: []const u8 = "",
    stored_block_height: i64 = -1,
    stored_block_hash: []const u8 = "",
    chainstate_backend: []const u8 = "rocksdb",
    chainstate_status: []const u8 = "missing",
    sync_status: []const u8 = "starting",
    chainstate_utxo_count: i64 = 0,
    chainstate_set_hash: []const u8 = "",
    current_blocker: []const u8 = "",
};

pub const CodecVectors = struct {
    pub const utxo_key_hex = "7508746573746e657434000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000001";
    pub const utxo_value_hex = "00000001000000012a05f200010000001976a914000102030405060708090a0b0c0d0e0f1011121388ac";
    pub const undo_key_hex = "6408746573746e65743400000002";
    pub const tip_key_hex = "7408746573746e657434";
    pub const block_index_key_hex = "6208746573746e65743400000002";
    pub const header_key_hex = "6808746573746e65743400000002";
    pub const metadata_key_hex = "6d0d636f6465635f76657273696f6e";
};

pub fn nowMs() i64 {
    var tv: c.struct_timeval = undefined;
    if (c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.tv_sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.tv_usec)), 1000);
}

pub fn rejectUnapprovedRuntimeDbArtifacts(path: []const u8) !void {
    const datadir = std.fs.path.dirname(path) orelse path;
    const datadir_z = try std.heap.c_allocator.dupeZ(u8, datadir);
    defer std.heap.c_allocator.free(datadir_z);
    const dir = c.opendir(datadir_z.ptr) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.ascii.endsWithIgnoreCase(name, ".db") or
            std.ascii.endsWithIgnoreCase(name, ".sqlite") or
            std.ascii.endsWithIgnoreCase(name, ".sqlite3"))
        {
            return error.ForbiddenRuntimeDbArtifact;
        }
    }
}

pub fn encodeUtxoKey(allocator: std.mem.Allocator, chain: []const u8, outpoint: Outpoint) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try encodeUtxoKeyInto(allocator, &bytes, chain, outpoint);
    return bytes.toOwnedSlice(allocator);
}

pub fn encodeUtxoKeyInto(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), chain: []const u8, outpoint: Outpoint) !void {
    try bytes.append(allocator, 'u');
    try appendVarBytes(allocator, bytes, chain);
    try bytes.appendSlice(allocator, outpoint.txid[0..]);
    try appendU32Be(allocator, bytes, outpoint.vout);
}

pub fn encodedUtxoKeyLen(chain: []const u8) !usize {
    if (chain.len > 252) return error.ValueTooLarge;
    return 1 + 1 + chain.len + 32 + 4;
}

pub fn encodeUtxoValue(allocator: std.mem.Allocator, utxo: StoredUtxo) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, utxo.height);
    try appendU64Be(allocator, &bytes, utxo.value_sats);
    try bytes.append(allocator, if (utxo.coinbase) 1 else 0);
    try appendVarBytes32(allocator, &bytes, utxo.script_pubkey);
    return bytes.toOwnedSlice(allocator);
}

pub fn encodeUndoKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'd', chain, height);
}

pub fn encodeTipKey(allocator: std.mem.Allocator, chain: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, 't');
    try appendVarBytes(allocator, &bytes, chain);
    return bytes.toOwnedSlice(allocator);
}

pub fn encodeBlockIndexKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'b', chain, height);
}

pub fn encodeHeaderKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'h', chain, height);
}

pub fn encodeRawBlockKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'r', chain, height);
}

pub fn encodeMetadataKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, 'm');
    try appendVarBytes(allocator, &bytes, name);
    return bytes.toOwnedSlice(allocator);
}

pub fn toHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn fromHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    var out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return out;
}

pub fn verifyCodecVectors(allocator: std.mem.Allocator) !void {
    var txid: [32]u8 = undefined;
    for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
    const script_bytes = try fromHexAlloc(allocator, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    defer allocator.free(script_bytes);

    const key = try encodeUtxoKey(allocator, "testnet4", .{ .txid = txid, .vout = 1 });
    defer allocator.free(key);
    const key_hex = try toHexAlloc(allocator, key);
    defer allocator.free(key_hex);
    if (!std.mem.eql(u8, key_hex, CodecVectors.utxo_key_hex)) return error.CodecVectorMismatch;

    const value = try encodeUtxoValue(allocator, .{
        .height = 1,
        .vout = 1,
        .value_sats = 5_000_000_000,
        .coinbase = true,
        .script_pubkey = script_bytes,
    });
    defer allocator.free(value);
    const value_hex = try toHexAlloc(allocator, value);
    defer allocator.free(value_hex);
    if (!std.mem.eql(u8, value_hex, CodecVectors.utxo_value_hex)) return error.CodecVectorMismatch;

    const undo_key = try encodeUndoKey(allocator, "testnet4", 2);
    defer allocator.free(undo_key);
    const undo_hex = try toHexAlloc(allocator, undo_key);
    defer allocator.free(undo_hex);
    if (!std.mem.eql(u8, undo_hex, CodecVectors.undo_key_hex)) return error.CodecVectorMismatch;

    const tip_key = try encodeTipKey(allocator, "testnet4");
    defer allocator.free(tip_key);
    const tip_hex = try toHexAlloc(allocator, tip_key);
    defer allocator.free(tip_hex);
    if (!std.mem.eql(u8, tip_hex, CodecVectors.tip_key_hex)) return error.CodecVectorMismatch;

    const block_index_key = try encodeBlockIndexKey(allocator, "testnet4", 2);
    defer allocator.free(block_index_key);
    const block_index_hex = try toHexAlloc(allocator, block_index_key);
    defer allocator.free(block_index_hex);
    if (!std.mem.eql(u8, block_index_hex, CodecVectors.block_index_key_hex)) return error.CodecVectorMismatch;

    const header_key = try encodeHeaderKey(allocator, "testnet4", 2);
    defer allocator.free(header_key);
    const header_hex = try toHexAlloc(allocator, header_key);
    defer allocator.free(header_hex);
    if (!std.mem.eql(u8, header_hex, CodecVectors.header_key_hex)) return error.CodecVectorMismatch;

    const metadata_key = try encodeMetadataKey(allocator, "codec_version");
    defer allocator.free(metadata_key);
    const metadata_hex = try toHexAlloc(allocator, metadata_key);
    defer allocator.free(metadata_hex);
    if (!std.mem.eql(u8, metadata_hex, CodecVectors.metadata_key_hex)) return error.CodecVectorMismatch;
}

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

pub fn encodeTipValue(allocator: std.mem.Allocator, height: u32, block_hash: [32]u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, height);
    try bytes.appendSlice(allocator, block_hash[0..]);
    return bytes.toOwnedSlice(allocator);
}

pub fn encodeUndoValue(allocator: std.mem.Allocator, entries: []const UndoEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, @intCast(entries.len));
    for (entries) |entry| {
        try bytes.appendSlice(allocator, entry.outpoint.txid[0..]);
        try appendU32Be(allocator, &bytes, entry.outpoint.vout);
        try appendU32Be(allocator, &bytes, entry.utxo.height);
        try appendU64Be(allocator, &bytes, entry.utxo.value_sats);
        try bytes.append(allocator, if (entry.utxo.coinbase) 1 else 0);
        try appendVarBytes32(allocator, &bytes, entry.utxo.script_pubkey);
    }
    return bytes.toOwnedSlice(allocator);
}

pub fn decodeUtxoValue(allocator: std.mem.Allocator, outpoint: Outpoint, value: []const u8) !StoredUtxo {
    if (value.len < 17) return error.UtxoValueTooShort;
    const height = std.mem.readInt(u32, value[0..4], .big);
    const value_sats = std.mem.readInt(u64, value[4..12], .big);
    const coinbase = value[12] == 1;
    const script_len = std.mem.readInt(u32, value[13..17], .big);
    if (17 + script_len > value.len) return error.UtxoValueTruncatedScript;
    return .{
        .height = height,
        .vout = outpoint.vout,
        .value_sats = value_sats,
        .coinbase = coinbase,
        .script_pubkey = try allocator.dupe(u8, value[17 .. 17 + script_len]),
    };
}

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

pub const CommitTimings = struct {
    utxo_delete_prepare: i64 = 0,
    utxo_put_prepare: i64 = 0,
    undo_put_prepare: i64 = 0,
    metadata_put_prepare: i64 = 0,
    rocksdb_write: i64 = 0,
    set_hash_fold: i64 = 0,
    snapshot: i64 = 0,

    pub fn total(self: CommitTimings) i64 {
        return self.utxo_delete_prepare + self.utxo_put_prepare + self.undo_put_prepare + self.metadata_put_prepare + self.rocksdb_write + self.set_hash_fold;
    }
};

pub const UtxoLoadStats = struct {
    lookup_count: u64 = 0,
    key_bytes: u64 = 0,
    value_bytes: u64 = 0,
    utxo_hit_ns: u64 = 0,
    utxo_miss_ns: u64 = 0,
    utxo_hit_count: u64 = 0,
    utxo_miss_count: u64 = 0,
};

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

pub const ConnectResult = struct {
    validated_height: u32,
    validated_hash: []u8,
    chainstate_utxo_count: i64,
    blocks_connected: u32,
    timings: ConnectTimings,

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

pub fn defaultScriptThreadCount() usize {
    const cpu_count = std.Thread.getCpuCount() catch 2;
    const minus_one = if (cpu_count > 1) cpu_count - 1 else 1;
    return @min(@max(minus_one, 1), 8);
}

pub const ScriptCryptoBackend = enum {
    native,
    own_curve,
    pure,

    pub fn label(self: ScriptCryptoBackend) []const u8 {
        return switch (self) {
            .native => "libsecp256k1",
            .own_curve => "libsecp256k1-zig",
            .pure => "zig-secp256k1",
        };
    }
};

pub const ScriptVerifyRunner = struct {
    allocator: std.mem.Allocator,
    thread_count: usize,
    crypto_backend: ScriptCryptoBackend,

    pub fn create(allocator: std.mem.Allocator, requested_threads: usize) !*ScriptVerifyRunner {
        return createWithCryptoBackend(allocator, requested_threads, if (crypto.own_curve) .own_curve else .native);
    }

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

    pub fn destroy(self: *ScriptVerifyRunner) void {
        self.allocator.destroy(self);
    }

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
    if (transactions.len == 0) return error.BlockWithoutTransactions;

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

fn elapsedMs(start_ms: i64) i64 {
    return @max(0, nowMs() - start_ms);
}

pub fn secp256k1Available() bool {
    return crypto.available();
}

fn keyWithHeight(allocator: std.mem.Allocator, prefix: u8, chain: []const u8, height: u32) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, prefix);
    try appendVarBytes(allocator, &bytes, chain);
    try appendU32Be(allocator, &bytes, height);
    return bytes.toOwnedSlice(allocator);
}

fn appendVarBytes(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > 252) return error.ValueTooLarge;
    try bytes.append(allocator, @intCast(value.len));
    try bytes.appendSlice(allocator, value);
}

fn appendVarBytes32(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try appendU32Be(allocator, bytes, @intCast(value.len));
    try bytes.appendSlice(allocator, value);
}

fn appendU32Be(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendU64Be(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u64) !void {
    try bytes.append(allocator, @intCast((value >> 56) & 0xff));
    try bytes.append(allocator, @intCast((value >> 48) & 0xff));
    try bytes.append(allocator, @intCast((value >> 40) & 0xff));
    try bytes.append(allocator, @intCast((value >> 32) & 0xff));
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendU64Le(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u64) !void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 32) & 0xff));
    try bytes.append(allocator, @intCast((value >> 40) & 0xff));
    try bytes.append(allocator, @intCast((value >> 48) & 0xff));
    try bytes.append(allocator, @intCast((value >> 56) & 0xff));
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}

pub const DatadirLock = struct {
    fd: std.c.fd_t,

    pub fn acquire(allocator: std.mem.Allocator, datadir: []const u8) !DatadirLock {
        const path = try std.fs.path.join(allocator, &.{ datadir, PortInfo.lock_file });
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = std.c.open(path_z, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
        }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.DatadirLock;
        if (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
            _ = std.c.close(fd);
            return error.DatadirBusy;
        }
        return .{ .fd = fd };
    }

    pub fn release(self: DatadirLock) void {
        _ = std.c.flock(self.fd, std.posix.LOCK.UN);
        _ = std.c.close(self.fd);
    }
};

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
}
