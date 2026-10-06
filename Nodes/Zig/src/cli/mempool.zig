const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const sync = @import("sync.zig");
const valueArg = common.valueArg;
const appendToolchainProvenance = common.appendToolchainProvenance;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const cmdLocalReferenceProof = sync.cmdLocalReferenceProof;

pub fn cmdRung0(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, default_peer: []const u8, default_crypto_backend: []const u8) !void {
    const command = args[0];
    const flags = args[1..];
    const trace_dir = valueArg(flags, "--trace") orelse return error.MissingTrace;
    const datadir = valueArg(flags, "--datadir") orelse core.types.PortInfo.default_datadir;
    const store_name = valueArg(flags, "--store") orelse "rocksdb";
    const info = try core.rung0.loadTraceInfo(allocator, io, trace_dir);
    defer info.deinit(allocator);
    const synthetic = std.mem.eql(u8, info.fixture, "synthetic");
    if (!synthetic) {
        const target_text = try std.fmt.allocPrint(allocator, "{d}", .{info.start_height});
        defer allocator.free(target_text);
        const sync_output = try std.fmt.allocPrint(allocator, "/tmp/zig-mempool-sync-{s}.json", .{store_name});
        defer allocator.free(sync_output);
        const peer = valueArg(flags, "--peer") orelse default_peer;
        const sync_flags = [_][]const u8{
            "--datadir", datadir,
            "--store",   store_name,
            "--target",  target_text,
            "--peer",    peer,
            "--output",  sync_output,
        };
        const prefetch_text = "4";
        try cmdLocalReferenceProof(allocator, io, out, sync_flags[0..], surface, prefetch_text, "", default_peer, default_crypto_backend);
    }
    const db_path = try std.fs.path.join(allocator, &.{ datadir, if (std.mem.eql(u8, store_name, "native")) core.types.PortInfo.native_dir else core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        var db = try core.native_store.NativeStore.open(allocator, db_path, .{});
        defer db.close();
        try finishRung0(allocator, io, out, &db, command, flags, info, surface, store_name, synthetic);
    } else if (comptime core.rocksdb_compiled) {
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try finishRung0(allocator, io, out, &db, command, flags, info, surface, store_name, synthetic);
    } else return error.UnsupportedStore;
}

fn finishRung0(allocator: std.mem.Allocator, io: std.Io, out: anytype, db: anytype, command: []const u8, flags: []const []const u8, info: core.rung0.TraceInfo, surface: []const u8, store_name: []const u8, synthetic: bool) !void {
    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    if (!synthetic) {
        if (!std.mem.eql(u8, meta.validated_hash, info.start_hash)) {
            try out.print("gate tip_hash=fail have={s} want={s}\n", .{ meta.validated_hash, info.start_hash });
            return error.TipHashMismatch;
        }
    }
    var report = try core.rung0.replay(allocator, io, db, info.trace_dir, out);
    defer report.deinit(allocator);
    const mempool_out = if (std.mem.eql(u8, command, "mempool-replay")) valueArg(flags, "--output") else null;
    const template_out = if (std.mem.eql(u8, command, "build-template")) valueArg(flags, "--output") else valueArg(flags, "--template-output");
    if (mempool_out) |path| try writeMempoolGate(allocator, io, path, report, info, surface, store_name);
    if (template_out) |path| try writeMiningGate(allocator, io, path, report, info, surface, store_name);
}

fn writeMempoolGate(allocator: std.mem.Allocator, io: std.Io, path: []const u8, report: core.rung0.Report, info: core.rung0.TraceInfo, surface: []const u8, store_name: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const verdicts = if (report.verdict_mismatches == 0) "pass" else "fail";
    const mutations = if (report.mutation_mismatches == 0) "pass" else "fail";
    try body.print(allocator,
        \\{{"schema":"port.mempool.rung0.v1","port":"zig","runtime_surface":"{s}","store":"{s}","passed":{s},"trace_dir":"{s}","fixture":"{s}","tx_checked":{d},"verdict_mismatches":{d},"mutation_checked":{d},"mutation_mismatches":{d},"results":[{{"fixture_id":"mempool.layer1_verdicts","result":"{s}"}},{{"fixture_id":"mempool.mutation_rejects","result":"{s}"}},{{"fixture_id":"mempool.block_connect_eviction","result":"{s}"}},{{"fixture_id":"mempool.trace_replay_set_hash","result":"recorded"}}],"boundaries":[
    , .{ surface, store_name, if (report.verdict_mismatches == 0 and report.mutation_mismatches == 0) "true" else "false", info.trace_dir, info.fixture, report.tx_checked, report.verdict_mismatches, report.mutation_checked, report.mutation_mismatches, verdicts, mutations, verdicts });
    for (report.boundaries, 0..) |row, i| {
        if (i != 0) try body.append(allocator, ',');
        try body.print(allocator, "{{\"height\":{d},\"set_hash\":\"{s}\",\"pool\":{d},\"core_set_hash\":\"{s}\"}}", .{ row.height, row.set_hash, row.pool_count, row.core_set_hash });
    }
    try body.appendSlice(allocator, "]");
    try appendToolchainProvenance(allocator, &body);
    try body.appendSlice(allocator, "}\n");
    try writeFileEnsuringParent(io, path, body.items);
}

fn writeMiningGate(allocator: std.mem.Allocator, io: std.Io, path: []const u8, report: core.rung0.Report, info: core.rung0.TraceInfo, surface: []const u8, store_name: []const u8) !void {
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
