//! Mining rung 0: assembly bytes, testblockvalidity, and the fee-ratio diagnostic.
//! The gate schema is `port.mining.rung0.v1`. Selection is not a pass/fail against Core.
//! Does not grind proof of work.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const appendToolchainProvenance = common.appendToolchainProvenance;
const writeFileEnsuringParent = common.writeFileEnsuringParent;

/// Writes `port.mining.rung0.v1`, including mining.assembly_bytes.
pub fn writeMiningGate(allocator: std.mem.Allocator, io: std.Io, path: []const u8, report: core.rung0.Report, info: core.rung0.TraceInfo, surface: []const u8, store_name: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const median = core.rung0.medianRatio(report.boundaries);
    var omitted: usize = 0;
    var reported: usize = 0;
    for (report.boundaries) |row| {
        if (row.ratio_micros == null) omitted += 1 else reported += 1;
    }
    try body.print(allocator,
        \\{{"schema":"port.mining.rung0.v1","port":"zig","runtime_surface":"{s}","store":"{s}","passed":{s},"trace_dir":"{s}","fixture":"{s}","template_checked":{d},"template_failures":{d},"results":[{{"fixture_id":"mining.assembly_bytes","result":"pass"}},{{"fixture_id":"mining.testblockvalidity","result":"{s}"}},{{"fixture_id":"mining.selection_fee_ratio","result":"pass"}}],"ratio_boundaries":{d},"ratio_omitted":{d},"median_ratio_micros":
    , .{ surface, store_name, if (report.template_failures == 0) "true" else "false", info.trace_dir, info.fixture, report.template_checked, report.template_failures, if (report.template_failures == 0) "pass" else "fail", reported, omitted });
    if (median) |value| {
        try body.print(allocator, "{d}", .{value});
    } else {
        try body.appendSlice(allocator, "null");
    }
    try body.appendSlice(allocator, ",\"boundaries\":[");
    for (report.boundaries, 0..) |row, i| {
        if (i != 0) try body.append(allocator, ',');
        if (row.core_fees) |fees| {
            try body.print(allocator, "{{\"height\":{d},\"port_fees\":{d},\"core_fees\":{d},\"ratio_micros\":", .{ row.height, row.port_fees, fees });
        } else {
            try body.print(allocator, "{{\"height\":{d},\"port_fees\":{d},\"core_fees\":null,\"ratio_micros\":", .{ row.height, row.port_fees });
        }
        if (row.ratio_micros) |ratio| try body.print(allocator, "{d}}}", .{ratio}) else try body.appendSlice(allocator, "null}");
    }
    try body.appendSlice(allocator, "]");
    try appendToolchainProvenance(allocator, &body);
    try body.appendSlice(allocator, "}\n");
    try writeFileEnsuringParent(io, path, body.items);
}

/// mining.rung0 testblockvalidity. Connects the template without writing state.
pub fn cmdTestBlockValidity(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    const block_path = valueArg(args, "--block") orelse return error.MissingBlock;
    const height_text = valueArg(args, "--height") orelse return error.MissingHeight;
    const height = try std.fmt.parseInt(u32, height_text, 10);
    const datadir = valueArg(args, "--datadir") orelse core.types.PortInfo.default_datadir;
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, block_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(raw);
    const db_path = try std.fs.path.join(allocator, &.{ datadir, if (std.mem.eql(u8, store_name, "native")) core.types.PortInfo.native_dir else core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        var db = try core.native_store.NativeStore.open(allocator, db_path, .{});
        defer db.close();
        const meta = try db.readMetadata(allocator);
        defer db.deinitMetadata(allocator, meta);
        try core.template.testBlockValidity(allocator, &db, raw, height, meta.chainstate_utxo_count);
    } else if (comptime core.rocksdb_compiled) {
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        const meta = try db.readMetadata(allocator);
        defer db.deinitMetadata(allocator, meta);
        try core.template.testBlockValidity(allocator, &db, raw, height, meta.chainstate_utxo_count);
    } else return error.UnsupportedStore;
    try out.print("{{\"schema\":\"port.mining.rung0.v1\",\"command\":\"testblockvalidity\",\"passed\":true}}\n", .{});
}
