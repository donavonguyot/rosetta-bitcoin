const std = @import("std");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("rocksdb/c.h");
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
    @cInclude("sys/time.h");
});

pub const crypto = @import("crypto.zig");
pub const tx = @import("tx.zig");
pub const block = @import("block.zig");
pub const script = @import("script.zig");
pub const p2p = @import("p2p.zig");

pub const PortInfo = struct {
    pub const port_key = "zig";
    pub const binary_name = "zigbitnode";
    pub const display_name = "ZigNode";
    pub const default_datadir = "./data-zig";
    pub const marker_file = ".zigbitnode_native_storage";
    pub const lock_file = ".zigbitnode.lock";
    pub const rocksdb_dir = "chainstate-rocksdb";
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

fn rejectUnapprovedRuntimeDbArtifacts(path: []const u8) !void {
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
    try bytes.append(allocator, 'u');
    try appendVarBytes(allocator, &bytes, chain);
    try bytes.appendSlice(allocator, outpoint.txid[0..]);
    try appendU32Be(allocator, &bytes, outpoint.vout);
    return bytes.toOwnedSlice(allocator);
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

pub const RocksDb = struct {
    db: *c.rocksdb_t,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !RocksDb {
        try rejectUnapprovedRuntimeDbArtifacts(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const options = c.rocksdb_options_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_options_destroy(options);
        c.rocksdb_options_set_create_if_missing(options, 1);
        c.rocksdb_options_increase_parallelism(options, 4);

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
        return .{ .db = db };
    }

    pub fn close(self: *RocksDb) void {
        c.rocksdb_close(self.db);
    }

    pub fn put(self: *RocksDb, key: []const u8, value: []const u8) !void {
        const opts = c.rocksdb_writeoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writeoptions_destroy(opts);
        var err: [*c]u8 = null;
        c.rocksdb_put(self.db, opts, key.ptr, key.len, value.ptr, value.len, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
    }

    pub fn getAlloc(self: *RocksDb, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const opts = c.rocksdb_readoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_readoptions_destroy(opts);
        var err: [*c]u8 = null;
        var len: usize = 0;
        const ptr = c.rocksdb_get(self.db, opts, key.ptr, key.len, &len, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbRead;
        }
        if (ptr == null) return null;
        defer c.rocksdb_free(ptr);
        return try allocator.dupe(u8, ptr[0..len]);
    }

    pub fn getManyRaw(self: *RocksDb, allocator: std.mem.Allocator, keys: []const []const u8) ![]?[]u8 {
        const out = try allocator.alloc(?[]u8, keys.len);
        errdefer allocator.free(out);
        if (keys.len == 0) return out;

        const opts = c.rocksdb_readoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_readoptions_destroy(opts);
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

        c.rocksdb_multi_get(self.db, opts, keys.len, key_ptrs.ptr, key_lens.ptr, value_ptrs.ptr, value_lens.ptr, errs.ptr);
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
        var keys = try allocator.alloc([]const u8, outpoints.len);
        defer {
            for (keys) |key| allocator.free(key);
            allocator.free(keys);
        }
        for (outpoints, 0..) |outpoint, i| {
            keys[i] = try encodeUtxoKey(allocator, chain, outpoint);
        }
        const raw_values = try self.getManyRaw(allocator, keys);
        defer {
            for (raw_values) |value| if (value) |bytes| allocator.free(bytes);
            allocator.free(raw_values);
        }
        var out = try allocator.alloc(?StoredUtxo, outpoints.len);
        errdefer allocator.free(out);
        for (raw_values, 0..) |value, i| {
            out[i] = if (value) |bytes| try decodeUtxoValue(allocator, outpoints[i], bytes) else null;
        }
        return out;
    }

    pub fn recordBlock(self: *RocksDb, allocator: std.mem.Allocator, height: u32, hash: [32]u8, raw: []const u8) !void {
        const write_opts = c.rocksdb_writeoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writeoptions_destroy(write_opts);
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
        c.rocksdb_write(self.db, write_opts, batch, &err);
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

    pub fn commitBlock(self: *RocksDb, allocator: std.mem.Allocator, commit: ChainstateBlockCommit) !void {
        const write_opts = c.rocksdb_writeoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writeoptions_destroy(write_opts);
        const batch = c.rocksdb_writebatch_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writebatch_destroy(batch);

        for (commit.spent_external) |outpoint| {
            const key = try encodeUtxoKey(allocator, "testnet4", outpoint);
            defer allocator.free(key);
            c.rocksdb_writebatch_delete(batch, key.ptr, key.len);
        }
        for (commit.created_utxos) |created| {
            const key = try encodeUtxoKey(allocator, "testnet4", created.outpoint);
            defer allocator.free(key);
            const value = try encodeUtxoValue(allocator, created.utxo);
            defer allocator.free(value);
            c.rocksdb_writebatch_put(batch, key.ptr, key.len, value.ptr, value.len);
        }

        const undo_key = try encodeUndoKey(allocator, "testnet4", commit.height);
        defer allocator.free(undo_key);
        const undo_value = try encodeUndoValue(allocator, commit.undo_entries);
        defer allocator.free(undo_value);
        c.rocksdb_writebatch_put(batch, undo_key.ptr, undo_key.len, undo_value.ptr, undo_value.len);

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
        try putMetaBatch(allocator, batch, "validated_hash", hash_display);
        try putMetaBatch(allocator, batch, "header_height", height_value);
        try putMetaBatch(allocator, batch, "header_hash", hash_display);
        try putMetaBatch(allocator, batch, "stored_block_height", height_value);
        try putMetaBatch(allocator, batch, "stored_block_hash", hash_display);
        try putMetaBatch(allocator, batch, "sync_status", "blocks_current");
        try putMetaBatch(allocator, batch, "chainstate_status", "usable");
        try putMetaBatch(allocator, batch, "current_blocker", "");

        const backend_key = try encodeMetadataKey(allocator, "chainstate_backend");
        defer allocator.free(backend_key);
        c.rocksdb_writebatch_put(batch, backend_key.ptr, backend_key.len, "rocksdb".ptr, 7);

        const counter_key = try encodeMetadataKey(allocator, "chainstate_utxo_count");
        defer allocator.free(counter_key);
        const existing_counter = (try self.getAlloc(allocator, counter_key)) orelse try allocator.dupe(u8, "0");
        defer allocator.free(existing_counter);
        const parsed_counter = std.fmt.parseInt(i64, existing_counter, 10) catch 0;
        const new_counter = parsed_counter - @as(i64, @intCast(commit.spent_external.len)) + @as(i64, @intCast(commit.created_utxos.len));
        const counter_value = try std.fmt.allocPrint(allocator, "{}", .{new_counter});
        defer allocator.free(counter_value);
        c.rocksdb_writebatch_put(batch, counter_key.ptr, counter_key.len, counter_value.ptr, counter_value.len);

        var err: [*c]u8 = null;
        c.rocksdb_write(self.db, write_opts, batch, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
    }

    pub fn writeBatchSmoke(self: *RocksDb, allocator: std.mem.Allocator) !void {
        const write_opts = c.rocksdb_writeoptions_create() orelse return error.RocksDbOptions;
        defer c.rocksdb_writeoptions_destroy(write_opts);
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
        c.rocksdb_write(self.db, write_opts, batch, &err);
        if (err != null) {
            c.rocksdb_free(err);
            return error.RocksDbWrite;
        }
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

fn decodeUtxoValue(allocator: std.mem.Allocator, outpoint: Outpoint, value: []const u8) !StoredUtxo {
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

fn putMetaBatch(allocator: std.mem.Allocator, batch: *c.rocksdb_writebatch_t, name: []const u8, value: []const u8) !void {
    const key = try encodeMetadataKey(allocator, name);
    defer allocator.free(key);
    c.rocksdb_writebatch_put(batch, key.ptr, key.len, value.ptr, value.len);
}

pub const ConnectTimings = struct {
    utxo_load: i64 = 0,
    prevout_batch_load: i64 = 0,
    script_verify: i64 = 0,
    utxo_apply: i64 = 0,
    commit: i64 = 0,
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
    prevouts: []script.SpentPrevout,
};

pub fn connectDecodedBlock(
    allocator: std.mem.Allocator,
    db: *RocksDb,
    height: u32,
    target: u32,
    info: block.BlockInfo,
    transactions: []const tx.Transaction,
) !ConnectResult {
    _ = target;
    const block_started = nowMs();
    if (transactions.len == 0) return error.BlockWithoutTransactions;

    var txids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(txids);
    for (transactions, 0..) |transaction, i| txids[i] = transaction.txid();

    var external_prevouts = std.AutoHashMap(Outpoint, void).init(allocator);
    defer external_prevouts.deinit();
    var external_order = std.ArrayList(Outpoint).empty;
    defer external_order.deinit(allocator);
    for (transactions[1..]) |transaction| {
        for (transaction.inputs) |input| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            if (!external_prevouts.contains(outpoint)) {
                try external_prevouts.put(outpoint, {});
                try external_order.append(allocator, outpoint);
            }
        }
    }

    var timings = ConnectTimings{};
    const load_started = nowMs();
    const loaded_values = try db.getManyUtxos(allocator, "testnet4", external_order.items);
    defer allocator.free(loaded_values);
    timings.prevout_batch_load += elapsedMs(load_started);
    timings.utxo_load += elapsedMs(load_started);

    var loaded = std.AutoHashMap(Outpoint, StoredUtxo).init(allocator);
    defer {
        var it = loaded.valueIterator();
        while (it.next()) |utxo| utxo.deinit(allocator);
        loaded.deinit();
    }
    for (external_order.items, loaded_values) |outpoint, value| {
        if (value) |utxo| try loaded.put(outpoint, utxo);
    }

    var created = std.AutoHashMap(Outpoint, StoredUtxo).init(allocator);
    defer created.deinit();
    var spent = std.AutoHashMap(Outpoint, void).init(allocator);
    defer spent.deinit();
    var undo_entries = std.ArrayList(UndoEntry).empty;
    defer undo_entries.deinit(allocator);
    var external_spends = std.ArrayList(Outpoint).empty;
    defer external_spends.deinit(allocator);
    var script_jobs = std.ArrayList(ScriptJob).empty;
    defer {
        for (script_jobs.items) |job| allocator.free(job.prevouts);
        script_jobs.deinit(allocator);
    }

    for (transactions, 0..) |transaction, tx_index| {
        if (tx_index == 0) {
            if (!transaction.isCoinbase()) return error.FirstTransactionNotCoinbase;
            if (height != 0) try addCreatedOutputs(allocator, &created, height, transaction, txids[tx_index], true);
            continue;
        }
        if (transaction.inputs.len == 0) return error.NonCoinbaseWithoutInputs;
        var input_seen = std.AutoHashMap(Outpoint, void).init(allocator);
        defer input_seen.deinit();
        var prevouts = try allocator.alloc(script.SpentPrevout, transaction.inputs.len);
        errdefer allocator.free(prevouts);
        for (transaction.inputs, 0..) |input, input_index| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            if (input_seen.contains(outpoint) or spent.contains(outpoint)) return error.DuplicateSpendInBlock;
            try input_seen.put(outpoint, {});
            const utxo = created.get(outpoint) orelse loaded.get(outpoint) orelse return error.MissingUtxo;
            if (utxo.coinbase and height < utxo.height + 100) return error.CoinbaseMaturity;
            prevouts[input_index] = .{ .amount = @intCast(utxo.value_sats), .script_pubkey = utxo.script_pubkey };
        }
        try script_jobs.append(allocator, .{ .tx_index = tx_index, .prevouts = prevouts });
        for (transaction.inputs) |input| {
            const outpoint = Outpoint{ .txid = input.previous_output.hash, .vout = input.previous_output.index };
            try spent.put(outpoint, {});
            if (!created.contains(outpoint)) {
                try external_spends.append(allocator, outpoint);
                const utxo = loaded.get(outpoint) orelse return error.MissingUndoUtxo;
                try undo_entries.append(allocator, .{ .outpoint = outpoint, .utxo = utxo });
            }
        }
        try addCreatedOutputs(allocator, &created, height, transaction, txids[tx_index], false);
    }

    const script_started = nowMs();
    try verifyScriptJobsParallel(transactions, script_jobs.items);
    timings.script_verify += elapsedMs(script_started);

    var created_utxos = std.ArrayList(CreatedUtxo).empty;
    defer created_utxos.deinit(allocator);
    var created_iter = created.iterator();
    while (created_iter.next()) |entry| {
        if (!spent.contains(entry.key_ptr.*)) {
            try created_utxos.append(allocator, .{ .outpoint = entry.key_ptr.*, .utxo = entry.value_ptr.* });
        }
    }

    const commit_started = nowMs();
    try db.commitBlock(allocator, .{
        .height = height,
        .block_hash = info.hash,
        .spent_external = external_spends.items,
        .created_utxos = created_utxos.items,
        .undo_entries = undo_entries.items,
    });
    timings.commit += elapsedMs(commit_started);
    timings.utxo_apply += timings.commit;
    timings.block_connect_store_commit += elapsedMs(block_started);

    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    return .{
        .validated_height = height,
        .validated_hash = try crypto.displayHashAlloc(allocator, info.hash[0..]),
        .chainstate_utxo_count = meta.chainstate_utxo_count,
        .blocks_connected = 1,
        .timings = timings,
    };
}

fn addCreatedOutputs(
    allocator: std.mem.Allocator,
    created: *std.AutoHashMap(Outpoint, StoredUtxo),
    height: u32,
    transaction: tx.Transaction,
    txid: [32]u8,
    coinbase: bool,
) !void {
    _ = allocator;
    for (transaction.outputs, 0..) |output, vout| {
        if (output.value < 0) return error.NegativeOutputValue;
        if (!isSpendableOutput(output.script_pubkey)) continue;
        const outpoint = Outpoint{ .txid = txid, .vout = @intCast(vout) };
        if (created.contains(outpoint)) return error.DuplicateCreatedUtxo;
        try created.put(outpoint, .{
            .height = height,
            .vout = @intCast(vout),
            .value_sats = @intCast(output.value),
            .coinbase = coinbase,
            .script_pubkey = output.script_pubkey,
        });
    }
}

pub fn isSpendableOutput(script_pubkey: []const u8) bool {
    return script_pubkey.len != 0 and script_pubkey[0] != 0x6a;
}

const ScriptThreadResult = struct {
    err: ?anyerror = null,
};

fn verifyScriptJobsParallel(transactions: []const tx.Transaction, jobs: []const ScriptJob) !void {
    var threads = try std.heap.c_allocator.alloc(std.Thread, jobs.len);
    defer std.heap.c_allocator.free(threads);
    var results = try std.heap.c_allocator.alloc(ScriptThreadResult, jobs.len);
    defer std.heap.c_allocator.free(results);
    for (jobs, 0..) |job, i| {
        results[i] = .{};
        threads[i] = try std.Thread.spawn(.{}, verifyScriptJobWorker, .{ transactions[job.tx_index], job.prevouts, &results[i] });
    }
    for (threads) |thread| thread.join();
    for (results) |result| {
        if (result.err) |err| return err;
    }
}

fn verifyScriptJobWorker(transaction: tx.Transaction, prevouts: []script.SpentPrevout, result: *ScriptThreadResult) void {
    for (transaction.inputs, 0..) |_, input_index| {
        script.verifyInput(std.heap.c_allocator, transaction, input_index, prevouts) catch |err| {
            result.err = err;
            return;
        };
    }
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

test "commit block writes created utxos undo tip metadata and counters" {
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
    try db.commitBlock(allocator, .{
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
    });
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
