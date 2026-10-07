//! `disconnect-tip` removes one committed block and prints the result.
//! The block bytes stay. A missing H−1 set hash is NoRecordedSetHash.
//! Does not walk a fork. `sync --allow-reorg-depth` does.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;

/// disconnect-tip gate. One block, JSON on stdout.
pub fn cmdDisconnectTip(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.types.PortInfo.default_datadir;
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const db_path = try std.fs.path.join(allocator, &.{ datadir, if (std.mem.eql(u8, store_name, "native")) core.types.PortInfo.native_dir else core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        var db = try core.native_store.NativeStore.open(allocator, db_path, .{});
        defer db.close();
        try finishDisconnect(allocator, out, &db, store_name);
    } else if (std.mem.eql(u8, store_name, "rocksdb")) {
        if (comptime !core.rocksdb_compiled) return error.StoreNotCompiled;
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try finishDisconnect(allocator, out, &db, store_name);
    } else return error.UnsupportedStore;
}

fn finishDisconnect(allocator: std.mem.Allocator, out: anytype, db: anytype, store_name: []const u8) !void {
    const result = try db.disconnectTip(allocator);
    const block_display = try core.crypto.displayHashAlloc(allocator, &result.block_hash);
    defer allocator.free(block_display);
    const tip_display = try core.crypto.displayHashAlloc(allocator, &result.new_tip_hash);
    defer allocator.free(tip_display);
    const set_hex = core.store.writeSetHashHex(result.set_hash_after);
    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    try out.print(
        "{{\"schema\":\"port.consensus.reorg.v1\",\"command\":\"disconnect-tip\",\"store\":\"{s}\",\"height\":{d},\"block_hash\":\"{s}\",\"new_tip_hash\":\"{s}\",\"utxos_removed\":{d},\"utxos_restored\":{d},\"set_hash_after\":\"{s}\",\"utxo_count\":{d}}}\n",
        .{ store_name, result.height, block_display, tip_display, result.utxos_removed, result.utxos_restored, set_hex[0..], meta.chainstate_utxo_count },
    );
}
