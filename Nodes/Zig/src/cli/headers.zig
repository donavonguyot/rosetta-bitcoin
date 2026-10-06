const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;

pub fn cmdCheckHeaders(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.types.PortInfo.default_datadir;
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const db_path = try std.fs.path.join(allocator, &.{ datadir, if (std.mem.eql(u8, store_name, "native")) core.types.PortInfo.native_dir else core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        var db = try core.native_store.NativeStore.open(allocator, db_path, .{});
        defer db.close();
        try finishCheckHeaders(allocator, out, &db, store_name);
    } else if (std.mem.eql(u8, store_name, "rocksdb")) {
        if (comptime !core.rocksdb_compiled) return error.StoreNotCompiled;
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try finishCheckHeaders(allocator, out, &db, store_name);
    } else return error.UnsupportedStore;
}

fn finishCheckHeaders(allocator: std.mem.Allocator, out: anytype, db: anytype, store_name: []const u8) !void {
    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    if (meta.validated_height < 155063) return error.TipTooLow;
    const tip: u32 = @intCast(meta.validated_height);
    const counts = try core.context_fixture.checkStoredHeaders(allocator, db, tip);
    try out.print("{{\"schema\":\"port.consensus_context.v1\",\"command\":\"check-headers\",\"store\":\"{s}\",\"tip\":{d},\"heights\":{d},\"retarget_boundaries\":{d},\"min_difficulty_blocks\":{d},\"timewarp_checks\":{d},\"passed\":true}}\n", .{ store_name, tip, counts.heights, counts.retarget_boundaries, counts.min_difficulty_blocks, counts.timewarp_checks });
}
