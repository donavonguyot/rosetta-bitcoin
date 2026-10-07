//! `check-headers` checks stored headers against the port nBits rule through the tip
//! and reports every broken prev_hash link in that extent.
//! The gate is check-headers (`zig_consensus_context_host_2026-10-04.json`).
//! Does not download headers.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;

/// check-headers gate through the stored tip.
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
    const report = try linkBreaks(allocator, db, tip);
    defer allocator.free(report.json);
    const passed = report.count == 0;
    try out.print("{{\"schema\":\"port.consensus_context.v1\",\"command\":\"check-headers\",\"store\":\"{s}\",\"tip\":{d},\"heights\":{d},\"retarget_boundaries\":{d},\"min_difficulty_blocks\":{d},\"timewarp_checks\":{d},\"link_breaks\":{s},\"passed\":{s}}}\n", .{ store_name, tip, counts.heights, counts.retarget_boundaries, counts.min_difficulty_blocks, counts.timewarp_checks, report.json, if (passed) "true" else "false" });
    if (!passed) return error.ParentLinkBreak;
}

const LinkReport = struct { json: []u8, count: usize };

fn linkBreaks(allocator: std.mem.Allocator, db: anytype, tip: u32) !LinkReport {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, '[');
    var height: u32 = 1;
    var count: usize = 0;
    while (height <= tip) : (height += 1) {
        const previous = (try db.headerAt(allocator, height - 1)) orelse return error.MissingHeader;
        const header = (try db.headerAt(allocator, height)) orelse return error.MissingHeader;
        const expected = core.crypto.doubleSha256(&previous);
        if (std.mem.eql(u8, header[4..36], &expected)) continue;
        if (count != 0) try body.append(allocator, ',');
        var stored_hex: [64]u8 = undefined;
        var expected_hex: [64]u8 = undefined;
        writeDisplayHex(&stored_hex, header[4..36]);
        writeDisplayHex(&expected_hex, &expected);
        const row = try std.fmt.allocPrint(allocator, "{{\"height\":{d},\"stored_prev\":\"{s}\",\"expected_prev\":\"{s}\"}}", .{ height, &stored_hex, &expected_hex });
        defer allocator.free(row);
        try body.appendSlice(allocator, row);
        count += 1;
    }
    try body.append(allocator, ']');
    return .{ .json = try body.toOwnedSlice(allocator), .count = count };
}

fn writeDisplayHex(out: *[64]u8, internal: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (0..32) |i| {
        const byte = internal[31 - i];
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}
