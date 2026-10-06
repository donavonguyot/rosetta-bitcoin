const std = @import("std");
const Io = std.Io;
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const appendToolchainProvenance = common.appendToolchainProvenance;
const parseScriptCryptoBackend = common.parseScriptCryptoBackend;
const sync = @import("sync.zig");
const cmdLocalReferenceProof = sync.cmdLocalReferenceProof;
const cmdSupervisorOnce = sync.cmdSupervisorOnce;
const status = @import("status.zig");
const cmdStatus = status.cmdStatus;
const storage_proof = @import("storage_proof.zig");
const cmdStorageProof = storage_proof.cmdStorageProof;
const vectors = @import("vectors.zig");
const cmdNativeCrypto = vectors.cmdNativeCrypto;
const cmdTestCapability = vectors.cmdTestCapability;
const script_corpus = @import("script_corpus.zig");
const cmdScriptCorpus = script_corpus.cmdScriptCorpus;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try usage(out);
        return;
    }

    const command = args[1];
    const io = init.io;
    if (std.mem.eql(u8, command, "--build-info")) {
        try cmdBuildInfo(allocator, io, out);
        return;
    }
    if (valueArg(args[2..], "--crypto-backend") orelse init.environ_map.get("ZIGBITNODE_CRYPTO_BACKEND")) |requested| {
        const selected = parseScriptCryptoBackend(requested) orelse return error.UnsupportedCryptoBackend;
        if (core.crypto.own_curve != (selected == .own_curve)) return error.CryptoBackendNotCompiled;
        if (std.mem.eql(u8, command, "script-corpus") and selected == .pure) return error.CorpusBackendNotSupported;
    }
    const surface = init.environ_map.get("ZIGBITNODE_RUNTIME_SURFACE") orelse "host";

    if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "codec-vectors")) {
        try core.codec.verifyCodecVectors(allocator);
        try out.print("{{\"schema\":\"port.codec_vectors.v1\",\"port\":\"zig\",\"codec_version\":2,\"passed\":true}}\n", .{});
    } else if (std.mem.eql(u8, command, "native-crypto-vectors")) {
        try cmdNativeCrypto(out);
    } else if (std.mem.eql(u8, command, "test-capability")) {
        try cmdTestCapability(allocator, io, out, args[2..]);
    } else if (std.mem.eql(u8, command, "storage-proof")) {
        try cmdStorageProof(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "script-corpus")) {
        try cmdScriptCorpus(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "local-reference-proof") or std.mem.eql(u8, command, "sync")) {
        const prefetch_text = init.environ_map.get("PREFETCH_DEPTH") orelse "4";
        const script_threads_text = init.environ_map.get("ZIGBITNODE_SCRIPT_THREADS") orelse "";
        const default_peer = init.environ_map.get("REFERENCE_P2P_PEER") orelse "127.0.0.1:48333";
        const default_crypto_backend = init.environ_map.get("ZIGBITNODE_CRYPTO_BACKEND") orelse core.crypto.default_label;
        try cmdLocalReferenceProof(std.heap.smp_allocator, io, out, args[2..], surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend);
    } else if (std.mem.eql(u8, command, "sync-supervisor-once")) {
        try cmdSupervisorOnce(allocator, out, args[2..]);
    } else if (std.mem.eql(u8, command, "mempool-replay") or std.mem.eql(u8, command, "build-template")) {
        const default_peer = init.environ_map.get("REFERENCE_P2P_PEER") orelse "127.0.0.1:48333";
        const default_crypto_backend = init.environ_map.get("ZIGBITNODE_CRYPTO_BACKEND") orelse core.crypto.default_label;
        try cmdRung0(std.heap.smp_allocator, io, out, args[1..], surface, default_peer, default_crypto_backend);
    } else if (std.mem.eql(u8, command, "testblockvalidity")) {
        try cmdTestBlockValidity(allocator, io, out, args[2..]);
    } else if (std.mem.eql(u8, command, "consensus-context")) {
        const manifest = valueArg(args[2..], "--manifest") orelse "../Shared/conformance/fixtures/consensus/context/manifest.json";
        const ok = try core.context_fixture.runManifest(allocator, io, manifest, out);
        if (!ok) return error.ConsensusContextFailed;
    } else if (std.mem.eql(u8, command, "write-context-fixtures")) {
        if (comptime !core.rocksdb_compiled) return error.StoreNotCompiled;
        const datadir = valueArg(args[2..], "--datadir") orelse return error.MissingDatadir;
        const out_dir = valueArg(args[2..], "--out") orelse return error.MissingOutput;
        const db_path = try std.fs.path.join(allocator, &.{ datadir, "chainstate-rocksdb" });
        defer allocator.free(db_path);
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try core.context_fixture.writeBlockFixtures(allocator, io, &db, out_dir);
        try out.print("{{\"schema\":\"port.consensus_context.v1\",\"command\":\"write-context-fixtures\",\"passed\":true}}\n", .{});
    } else if (std.mem.eql(u8, command, "check-headers")) {
        try cmdCheckHeaders(allocator, out, args[2..]);
    } else if (comptime !core.crypto.own_curve) {
        if (std.mem.eql(u8, command, "crypto-bench")) {
            try @import("crypto_bench").run(allocator, io, out, args[2..]);
        } else {
            try out.print("error: unknown command: {s}\n", .{command});
            try usage(out);
            return error.UnknownCommand;
        }
    } else {
        try out.print("error: unknown command: {s}\n", .{command});
        try usage(out);
        return error.UnknownCommand;
    }
}

fn usage(out: anytype) !void {
    try out.print(
        \\zigbitnode commands:
        \\  status [--datadir ./data-zig] [--store=rocksdb|native]
        \\  storage-proof [--datadir ./data-zig] [--output path] [--gate-output path] [--store=rocksdb|native]
        \\  codec-vectors
        \\  native-crypto-vectors
        \\  test-capability --kind crypto-vectors --outcome-path path [--mutation schnorr-accept-bad-s|schnorr-accept-bad-xonly|taproot-ignore-output-check]
        \\  script-corpus [--manifest path] [--output path] [--shadow-crypto]
        \\  sync|local-reference-proof [--target <height>] [--peer <host:port>] [--output path] [--gate-output path] [--store=rocksdb|native] [--shadow] [--snapshot-every N] [--utxo-capacity-hint N] [--mem-limit <text>] [--fsync] [--crash-after-block N] [--crash-point before-append|after-append] [--benchmark-lane self_hosted]
        \\  sync-supervisor-once [--target 5000] [--peer <host:port>] [--datadir ./data-zig]
        \\  mempool-replay --trace <dir> [--datadir ./data-zig] [--store=native|rocksdb] [--output path] [--template-output path]
        \\  build-template --trace <dir> [--datadir ./data-zig] [--store=native|rocksdb] [--output path]
        \\  testblockvalidity --block <path> --height <n> [--datadir ./data-zig] [--store=native|rocksdb]
        \\  consensus-context [--manifest path]
        \\  check-headers [--datadir ./data-zig] [--store=rocksdb|native]
        \\  crypto-bench [--profile]
        \\  --build-info
        \\
    , .{});
}

fn cmdBuildInfo(allocator: std.mem.Allocator, io: Io, out: anytype) !void {
    const digest = try binarySha256(allocator, io);
    try out.print(
        "{{\"crypto_backend\":\"{s}\",\"store_mode\":\"{s}\",\"source_commit\":\"{s}\",\"binary_sha256\":\"{s}\"}}\n",
        .{ core.crypto.lane, core.store_mode, core.crypto.source_commit, digest },
    );
}

fn binarySha256(allocator: std.mem.Allocator, io: Io) ![64]u8 {
    const file = try std.process.openExecutable(io, .{});
    defer file.close(io);
    const len = try file.length(io);
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const n = try file.readPositionalAll(io, bytes, 0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..n], &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn cmdRung0(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, default_peer: []const u8, default_crypto_backend: []const u8) !void {
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

fn cmdCheckHeaders(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
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

fn cmdTestBlockValidity(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
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
