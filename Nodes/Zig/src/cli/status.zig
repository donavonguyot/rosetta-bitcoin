//! `status` reads chainstate metadata for a datadir.
//! Operators use it to see validated height before another writer starts.
//! Does not connect blocks.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const tryMetadataKey = common.tryMetadataKey;

/// status. Reads validated height from the datadir.
pub fn cmdStatus(allocator: std.mem.Allocator, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.types.PortInfo.default_datadir;
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const db_path = try std.fs.path.join(allocator, &.{ datadir, if (std.mem.eql(u8, store_name, "native")) core.types.PortInfo.native_dir else core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);

    var validated_height: []const u8 = "0";
    var validated_hash: []const u8 = "";
    var header_height: []const u8 = "0";
    var header_hash: []const u8 = "";
    var stored_block_height: []const u8 = "0";
    var stored_block_hash: []const u8 = "";
    var validation_crypto: []const u8 = "unknown";
    var crypto_digest: []const u8 = "unknown";
    var backend: []const u8 = "none";
    var utxo_count: []const u8 = "0";
    var chainstate_status: []const u8 = "missing";
    var sync_status: []const u8 = "starting";
    var set_hash: []const u8 = "0000000000000000000000000000000000000000000000000000000000000000";
    if (std.mem.eql(u8, store_name, "native")) {
        if (core.native_store.NativeStore.open(allocator, db_path, .{})) |db0| {
            var db = db0;
            defer db.close();
            try readStatusFields(allocator, &db, &validated_height, &validated_hash, &header_height, &header_hash, &stored_block_height, &stored_block_hash, &backend, &utxo_count, &validation_crypto, &crypto_digest, &sync_status, &set_hash);
            chainstate_status = if (std.mem.eql(u8, backend, "rocksdb") or std.mem.eql(u8, backend, "native")) "usable" else "missing";
        } else |_| {}
    } else if (comptime !core.rocksdb_compiled) {
        try out.print("error: --store=rocksdb needs RocksDB, which this binary did not link; rebuild without -Dstore=native or pass --store=native\n", .{});
        return error.StoreNotCompiled;
    } else if (core.RocksDb.open(allocator, db_path)) |db0| {
        var db = db0;
        defer db.close();
        try readStatusFields(allocator, &db, &validated_height, &validated_hash, &header_height, &header_hash, &stored_block_height, &stored_block_hash, &backend, &utxo_count, &validation_crypto, &crypto_digest, &sync_status, &set_hash);
        chainstate_status = if (std.mem.eql(u8, backend, "rocksdb") or std.mem.eql(u8, backend, "native")) "usable" else "missing";
    } else |_| {}

    try out.print(
        "{{\"schema\":\"port.status.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"datadir\":\"{s}\",\"sync_status\":\"{s}\",\"chainstate_backend\":\"{s}\",\"chainstate_status\":\"{s}\",\"validated_height\":{s},\"validated_hash\":\"{s}\",\"header_height\":{s},\"header_hash\":\"{s}\",\"stored_block_height\":{s},\"stored_block_hash\":\"{s}\",\"chainstate_utxo_count\":{s},\"chainstate_set_hash\":\"{s}\",\"native_crypto_backend\":\"{s}\",\"native_crypto_available\":{},\"taproot_tweak_backend\":\"{s}\",\"crypto_backend\":\"{s}\",\"crypto_source_digest\":\"{s}\",\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\"}}\n",
        .{ surface, datadir, sync_status, backend, chainstate_status, validated_height, validated_hash, header_height, header_hash, stored_block_height, stored_block_hash, utxo_count, set_hash, validation_crypto, std.mem.eql(u8, validation_crypto, "libsecp256k1"), validation_crypto, validation_crypto, crypto_digest },
    );
}

fn readStatusFields(
    allocator: std.mem.Allocator,
    db: anytype,
    validated_height: *[]const u8,
    validated_hash: *[]const u8,
    header_height: *[]const u8,
    header_hash: *[]const u8,
    stored_block_height: *[]const u8,
    stored_block_hash: *[]const u8,
    backend: *[]const u8,
    utxo_count: *[]const u8,
    validation_crypto: *[]const u8,
    crypto_digest: *[]const u8,
    sync_status: *[]const u8,
    set_hash: *[]const u8,
) !void {
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "validated_height"))) |value| validated_height.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "validated_hash"))) |value| validated_hash.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "header_height"))) |value| header_height.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "header_hash"))) |value| header_hash.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "stored_block_height"))) |value| stored_block_height.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "stored_block_hash"))) |value| stored_block_hash.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_backend"))) |value| backend.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_utxo_count"))) |value| utxo_count.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "validation_crypto_backend"))) |value| validation_crypto.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "crypto_source_digest"))) |value| crypto_digest.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "sync_status"))) |value| sync_status.* = value;
    if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_set_hash"))) |value| set_hash.* = value;
}
