const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const toolchainProvenance = common.toolchainProvenance;
const nativeOpenOptions = common.nativeOpenOptions;
const optimizeName = common.optimizeName;

const ResultPaths = struct {
    storage: []const u8 = "../Shared/conformance/results/zig_storage_gate_docker_latest.json",
};

pub fn cmdStorageProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.types.PortInfo.default_datadir;
    const output = valueArg(args, "--output") orelse (ResultPaths{}).storage;
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    var lock = try core.datadir.DatadirLock.acquire(allocator, datadir);
    defer lock.release();
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    const store_name = valueArg(args, "--store") orelse "rocksdb";
    if (std.mem.eql(u8, store_name, "native")) {
        const native_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.native_dir });
        defer allocator.free(native_path);
        var native = try core.native_store.NativeStore.open(allocator, native_path, try nativeOpenOptions(args));
        defer native.close();
        try native.writeBatchSmoke(allocator);
        var pin_buf: [128]u8 = undefined;
        const pins = toolchainProvenance(&pin_buf);
        const json = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"port.storage_gate_result.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"storage_backend\":\"native\",\"runtime_truth_backend\":\"native\",\"rocksdb_runtime_truth\":false,\"durability_class\":\"process_crash\",\"native_marker\":\"{s}\",\"atomic_batch_commit\":true,\"validated_height\":2,\"chainstate_status\":\"usable\",\"chainstate_backend\":\"native\",\"chainstate_utxo_count\":1,\"binary_gate_status\":\"not_attempted\",\"current_blocker\":null{s}}}\n",
            .{ surface, core.types.PortInfo.marker_file, pins },
        );
        defer allocator.free(json);
        try writeFileEnsuringParent(io, output, json);
        try out.print("{s}", .{json});
        const set_hash = core.store.writeSetHashHex(native.setHash());
        const gate = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"port.native_store.gate.v1\",\"gate\":\"storage_proof\",\"height\":2,\"utxo_count\":1,\"reorg_tested\":false,\"peak_rss_bytes\":{},\"set_hash\":\"{s}\",\"snapshot_every\":{},\"runtime_surface\":\"{s}\",\"optimize\":\"{s}\",\"proof_scope\":\"storage_proof\",\"mechanism_tests\":\"zig build test\",\"peer_gates\":[\"shadow_5k\",\"shadow_50k\",\"storage_proof\"]{s}}}\n",
            .{ core.store.peakRssBytes(), set_hash[0..], native.options.snapshot_every, surface, optimizeName(), pins },
        );
        defer allocator.free(gate);
        try out.print("{s}", .{gate});
        if (valueArg(args, "--gate-output")) |path| try writeFileEnsuringParent(io, path, gate);
        return;
    }
    if (!std.mem.eql(u8, store_name, "rocksdb")) return error.UnsupportedStore;
    if (comptime !core.rocksdb_compiled) {
        try out.print("error: --store=rocksdb needs RocksDB, which this binary did not link; rebuild without -Dstore=native or pass --store=native\n", .{});
        return error.StoreNotCompiled;
    }

    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    var db = try core.RocksDb.open(allocator, db_path);
    defer db.close();
    try db.writeBatchSmoke(allocator);

    var pin_buf: [128]u8 = undefined;
    const pins = toolchainProvenance(&pin_buf);
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.storage_gate_result.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"storage_backend\":\"rocksdb\",\"runtime_truth_backend\":\"rocksdb\",\"rocksdb_runtime_truth\":true,\"native_marker\":\"{s}\",\"atomic_batch_commit\":true,\"validated_height\":2,\"chainstate_status\":\"usable\",\"chainstate_backend\":\"rocksdb\",\"chainstate_utxo_count\":1,\"binary_gate_status\":\"not_attempted\",\"current_blocker\":null{s}}}\n",
        .{ surface, core.types.PortInfo.marker_file, pins },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}
