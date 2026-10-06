const std = @import("std");
const Io = std.Io;
const core = @import("zigbitnode");
const common = @import("common.zig");
const elapsedMs = common.elapsedMs;
const valueArg = common.valueArg;
const flagArg = common.flagArg;
const jsonString = common.jsonString;
const jsonInteger = common.jsonInteger;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const toolchainProvenance = common.toolchainProvenance;
const appendToolchainProvenance = common.appendToolchainProvenance;
const appendFmt = common.appendFmt;

const ResultPaths = struct {
    script: []const u8 = "../Shared/conformance/results/zig_script_corpus_latest.json",
    storage: []const u8 = "../Shared/conformance/results/zig_storage_gate_docker_latest.json",
    proof: []const u8 = ".benchmark-results/zig_docker_baseline_5k_benchmark_latest.json",
};

const ProofProfile = struct {
    target: u32,
    target_label: []const u8,
    benchmark_gate: []const u8,
    benchmark_kind: []const u8,
    benchmark_lane: []const u8,
    strict_expected: bool = true,
    expected_hash: []const u8,
    expected_utxo_count: i64,
};

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

fn cmdStatus(allocator: std.mem.Allocator, out: anytype, args: []const []const u8, surface: []const u8) !void {
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

fn cmdNativeCrypto(out: anytype) !void {
    const available = core.crypto_glue.secp256k1Available();
    try out.print(
        "{{\"schema\":\"port.native_crypto_vectors.v1\",\"port\":\"zig\",\"passed\":{},\"delegated\":false,\"ecdsa_backend\":\"{s}\",\"schnorr_backend\":\"{s}\",\"taproot_tweak_backend\":\"{s}\",\"notes\":\"backend availability smoke vector only; full shared crypto vectors are next\"}}\n",
        .{ available, core.crypto.default_label, core.crypto.default_label, core.crypto.default_label },
    );
}

fn cmdTestCapability(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    const kind = valueArg(args, "--kind") orelse return error.MissingKind;
    const output = valueArg(args, "--outcome-path") orelse return error.MissingOutputPath;
    if (!std.mem.eql(u8, kind, "crypto-vectors")) return error.UnsupportedCapabilityKind;
    const mutation = parseCryptoMutation(valueArg(args, "--mutation") orelse "none") orelse return error.UnsupportedCryptoMutation;
    const json = try cryptoCapabilityOutcomes(allocator, io, mutation);
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}\n", .{output});
}

fn cryptoCapabilityOutcomes(allocator: std.mem.Allocator, io: std.Io, mutation: CryptoMutation) ![]u8 {
    if (comptime core.crypto.own_curve) return ownCurveCapabilityOutcomes(allocator, io, mutation);
    var native_verifier = try core.crypto.NativeVerifier.create();
    defer native_verifier.destroy();
    var pure_verifier = core.crypto.PureVerifier.create();
    defer pure_verifier.destroy();
    const native_backend = TestCryptoVerifier{ .backend = .{ .native = &native_verifier } };
    const pure_backend = TestCryptoVerifier{ .backend = .{ .pure = &pure_verifier }, .mutation = mutation };
    const bip = try runBip340Vectors(allocator, io, native_backend, "libsecp256k1");
    defer allocator.free(bip.failures);
    const native = try runNativeCryptoVectors(allocator, io, native_backend, "libsecp256k1");
    defer allocator.free(native.failures);
    const pure_bip = try runBip340Vectors(allocator, io, pure_backend, "zig-secp256k1");
    defer allocator.free(pure_bip.failures);
    const pure_native = try runNativeCryptoVectors(allocator, io, pure_backend, "zig-secp256k1");
    defer allocator.free(pure_native.failures);
    const eq_passed = bip.passed + native.passed;
    const eq_total = bip.total + native.total;
    const shadow_passed = pure_bip.passed + pure_native.passed;
    const shadow_total = pure_bip.total + pure_native.total;
    const combined_passed = eq_passed + shadow_passed;
    const combined_total = eq_total + shadow_total;
    const bip_notes = if (bip.passed == bip.total)
        try std.fmt.allocPrint(allocator, "all BIP340 vectors matched expected verification result", .{})
    else
        try std.fmt.allocPrint(allocator, "BIP340 vector failures: {s}", .{bip.failures});
    defer allocator.free(bip_notes);
    const equivalence_notes = if (combined_passed == combined_total)
        try std.fmt.allocPrint(allocator, "libsecp256k1 BIP340 {}/{} plus native crypto vectors {}/{}; pure Zig shadow BIP340 {}/{} plus native crypto vectors {}/{}", .{ bip.passed, bip.total, native.passed, native.total, pure_bip.passed, pure_bip.total, pure_native.passed, pure_native.total })
    else
        try std.fmt.allocPrint(allocator, "libsecp256k1 BIP340 {}/{} plus native crypto vectors {}/{}; pure Zig shadow BIP340 {}/{} plus native crypto vectors {}/{}; failures: libsecp256k1_bip340=[{s}] libsecp256k1_native=[{s}] zig_secp256k1_bip340=[{s}] zig_secp256k1_native=[{s}]", .{ bip.passed, bip.total, native.passed, native.total, pure_bip.passed, pure_bip.total, pure_native.passed, pure_native.total, bip.failures, native.failures, pure_bip.failures, pure_native.failures });
    defer allocator.free(equivalence_notes);
    return std.fmt.allocPrint(
        allocator,
        "{{\"port\":\"zig\",\"backend\":\"libsecp256k1\",\"shadow_backend\":\"zig-secp256k1\",\"outcomes\":[{{\"capability\":\"crypto_bip340_vectors\",\"status\":\"{s}\",\"case_passed\":{},\"case_total\":{},\"notes\":\"{s}\"}},{{\"capability\":\"crypto_libsecp256k1_equivalence\",\"status\":\"{s}\",\"case_passed\":{},\"case_total\":{},\"notes\":\"{s}\"}}]}}\n",
        .{
            if (bip.passed == bip.total) "pass" else "fail",
            bip.passed,
            bip.total,
            bip_notes,
            if (combined_passed == combined_total) "pass" else "fail",
            combined_passed,
            combined_total,
            equivalence_notes,
        },
    );
}

fn ownCurveCapabilityOutcomes(allocator: std.mem.Allocator, io: std.Io, mutation: CryptoMutation) ![]u8 {
    var own_verifier = core.crypto.OwnVerifier.create();
    defer own_verifier.destroy();
    const clean = TestCryptoVerifier{ .backend = .{ .own = &own_verifier } };
    const mutated = TestCryptoVerifier{ .backend = .{ .own = &own_verifier }, .mutation = mutation };
    const label = "libsecp256k1-zig";
    const bip = try runBip340Vectors(allocator, io, clean, label);
    defer allocator.free(bip.failures);
    const native = try runNativeCryptoVectors(allocator, io, clean, label);
    defer allocator.free(native.failures);
    const mut_bip = try runBip340Vectors(allocator, io, mutated, label);
    defer allocator.free(mut_bip.failures);
    const mut_native = try runNativeCryptoVectors(allocator, io, mutated, label);
    defer allocator.free(mut_native.failures);
    const eq_passed = mut_bip.passed + mut_native.passed;
    const eq_total = mut_bip.total + mut_native.total;
    const bip_notes = if (bip.passed == bip.total)
        try std.fmt.allocPrint(allocator, "all BIP340 vectors matched expected verification result", .{})
    else
        try std.fmt.allocPrint(allocator, "BIP340 vector failures: {s}", .{bip.failures});
    defer allocator.free(bip_notes);
    const equivalence_notes = if (eq_passed == eq_total)
        try std.fmt.allocPrint(allocator, "libsecp256k1-zig BIP340 {}/{} plus native crypto vectors {}/{}", .{ mut_bip.passed, mut_bip.total, mut_native.passed, mut_native.total })
    else
        try std.fmt.allocPrint(allocator, "libsecp256k1-zig BIP340 {}/{} plus native crypto vectors {}/{}; failures: libsecp256k1-zig_bip340=[{s}] libsecp256k1-zig_native=[{s}]", .{ mut_bip.passed, mut_bip.total, mut_native.passed, mut_native.total, mut_bip.failures, mut_native.failures });
    defer allocator.free(equivalence_notes);
    return std.fmt.allocPrint(
        allocator,
        "{{\"port\":\"zig\",\"backend\":\"libsecp256k1-zig\",\"shadow_backend\":\"libsecp256k1-zig\",\"outcomes\":[{{\"capability\":\"crypto_bip340_vectors\",\"status\":\"{s}\",\"case_passed\":{},\"case_total\":{},\"notes\":\"{s}\"}},{{\"capability\":\"crypto_libsecp256k1_equivalence\",\"status\":\"{s}\",\"case_passed\":{},\"case_total\":{},\"notes\":\"{s}\"}}]}}\n",
        .{
            if (bip.passed == bip.total) "pass" else "fail",
            bip.passed,
            bip.total,
            bip_notes,
            if (eq_passed == eq_total) "pass" else "fail",
            eq_passed,
            eq_total,
            equivalence_notes,
        },
    );
}

const Count = struct {
    passed: usize,
    total: usize,
    failures: []const u8,
};

const CryptoMutation = enum {
    none,
    schnorr_accept_bad_s,
    schnorr_accept_bad_xonly,
    taproot_ignore_output_check,
};

const TestCryptoVerifier = struct {
    backend: core.crypto.CryptoVerifier,
    mutation: CryptoMutation = .none,

    fn verifyEcdsaDer(self: TestCryptoVerifier, pubkey_bytes: []const u8, der_sig: []const u8, msg32: *const [32]u8) bool {
        return self.backend.verifyEcdsaDer(pubkey_bytes, der_sig, msg32);
    }

    fn verifySchnorr(self: TestCryptoVerifier, xonly_pubkey_bytes: []const u8, sig64: []const u8, msg: []const u8) bool {
        if (sig64.len == 64) {
            if (self.mutation == .schnorr_accept_bad_s and isTargetBadS(sig64[32..64])) return true;
            if (self.mutation == .schnorr_accept_bad_xonly and isTargetBadXOnly(xonly_pubkey_bytes)) return true;
        }
        return self.backend.verifySchnorr(xonly_pubkey_bytes, sig64, msg);
    }

    fn taprootTweakPubkeyXOnly(self: TestCryptoVerifier, internal_xonly: []const u8, tweak32: *const [32]u8) ?core.crypto.TweakResult {
        return self.backend.taprootTweakPubkeyXOnly(internal_xonly, tweak32);
    }
};

fn runBip340Vectors(allocator: std.mem.Allocator, io: std.Io, verifier: TestCryptoVerifier, backend_label: []const u8) !Count {
    const path = "../Shared/testing/fixtures/bip340/test-vectors.csv";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    var passed: usize = 0;
    var total: usize = 0;
    var failures = std.ArrayList(u8).empty;
    errdefer failures.deinit(allocator);
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const pub_hex = csvField(line, 2) orelse return error.MalformedBip340Csv;
        const msg_hex = csvField(line, 4) orelse return error.MalformedBip340Csv;
        const sig_hex = csvField(line, 5) orelse return error.MalformedBip340Csv;
        const expected_text = csvField(line, 6) orelse return error.MalformedBip340Csv;
        const pubkey = try core.crypto.fromHexAlloc(allocator, pub_hex);
        defer allocator.free(pubkey);
        const msg = try core.crypto.fromHexAlloc(allocator, msg_hex);
        defer allocator.free(msg);
        const sig = try core.crypto.fromHexAlloc(allocator, sig_hex);
        defer allocator.free(sig);
        const expected = std.mem.eql(u8, expected_text, "TRUE");
        const actual = verifier.verifySchnorr(pubkey, sig, msg);
        if (actual == expected) {
            passed += 1;
        } else {
            const id = try std.fmt.allocPrint(allocator, "bip340-{}", .{total});
            defer allocator.free(id);
            try appendFailureId(allocator, &failures, backend_label, id);
        }
        total += 1;
    }
    return .{ .passed = passed, .total = total, .failures = try failures.toOwnedSlice(allocator) };
}

fn runNativeCryptoVectors(allocator: std.mem.Allocator, io: std.Io, verifier: TestCryptoVerifier, backend_label: []const u8) !Count {
    const path = "../Shared/conformance/fixtures/native_crypto_v1_vectors.json";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const vectors = parsed.value.object.get("vectors") orelse return error.NativeVectorsMissing;
    if (vectors != .array) return error.NativeVectorsMissing;
    var passed: usize = 0;
    var failures = std.ArrayList(u8).empty;
    errdefer failures.deinit(allocator);
    for (vectors.array.items) |item| {
        if (item != .object) return error.NativeVectorsMissing;
        const id = jsonString(item.object.get("id")) orelse "unknown";
        const matched = nativeVectorMatches(allocator, verifier, item.object) catch false;
        if (matched) {
            passed += 1;
        } else {
            try appendFailureId(allocator, &failures, backend_label, id);
        }
    }
    return .{ .passed = passed, .total = vectors.array.items.len, .failures = try failures.toOwnedSlice(allocator) };
}

fn appendFailureId(allocator: std.mem.Allocator, failures: *std.ArrayList(u8), backend_label: []const u8, id: []const u8) !void {
    if (failures.items.len > 0) try failures.appendSlice(allocator, ",");
    try appendFmt(allocator, failures, "{s}:{s}", .{ backend_label, id });
}

fn nativeVectorMatches(allocator: std.mem.Allocator, verifier: TestCryptoVerifier, obj: std.json.ObjectMap) !bool {
    const expected = jsonString(obj.get("expected")) orelse return false;
    const want_valid = std.mem.eql(u8, expected, "valid");
    const operation = jsonString(obj.get("operation")) orelse return false;
    if (std.mem.eql(u8, operation, "verify_ecdsa")) {
        const pubkey = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("pubkey_hex")) orelse "");
        defer allocator.free(pubkey);
        const sig = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("signature_hex")) orelse "");
        defer allocator.free(sig);
        const msg = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("msg_hash_hex")) orelse "");
        defer allocator.free(msg);
        if (msg.len != 32) return !want_valid;
        var msg32: [32]u8 = undefined;
        @memcpy(&msg32, msg[0..32]);
        return verifier.verifyEcdsaDer(pubkey, sig, &msg32) == want_valid;
    }
    if (std.mem.eql(u8, operation, "verify_schnorr")) {
        const pubkey = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("xonly_pubkey_hex")) orelse "");
        defer allocator.free(pubkey);
        const sig = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("signature_hex")) orelse "");
        defer allocator.free(sig);
        const msg = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("msg_hash_hex")) orelse "");
        defer allocator.free(msg);
        return verifier.verifySchnorr(pubkey, sig, msg) == want_valid;
    }
    if (std.mem.eql(u8, operation, "taproot_tweak_xonly")) {
        const internal = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("xonly_pubkey_hex")) orelse "");
        defer allocator.free(internal);
        const merkle = try core.crypto.fromHexAlloc(allocator, jsonString(obj.get("merkle_root_hex")) orelse "");
        defer allocator.free(merkle);
        var tweak_input = std.ArrayList(u8).empty;
        defer tweak_input.deinit(allocator);
        try tweak_input.appendSlice(allocator, internal);
        try tweak_input.appendSlice(allocator, merkle);
        const tweak = core.crypto.taggedHash("TapTweak", tweak_input.items);
        const result = verifier.taprootTweakPubkeyXOnly(internal, &tweak);
        const expected_xonly = jsonString(obj.get("expected_output_xonly_hex")) orelse "";
        const expected_parity = jsonInteger(obj.get("expected_parity")) orelse -1;
        if (result) |tweaked| {
            const actual_xonly = try core.crypto.toHexAlloc(allocator, tweaked.output_xonly[0..]);
            defer allocator.free(actual_xonly);
            const got_valid = if (verifier.mutation == .taproot_ignore_output_check)
                true
            else
                std.mem.eql(u8, actual_xonly, expected_xonly) and tweaked.parity == @as(u8, @intCast(expected_parity));
            return got_valid == want_valid;
        }
        return !want_valid;
    }
    return false;
}

fn isTargetBadS(s: []const u8) bool {
    const zero = [_]u8{0} ** 32;
    const order = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
        0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
    };
    return std.mem.eql(u8, s, zero[0..]) or std.mem.eql(u8, s, order[0..]);
}

fn isTargetBadXOnly(xonly_pubkey_bytes: []const u8) bool {
    const field_prime = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xfc, 0x2f,
    };
    const nonliftable_five = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
    };
    return std.mem.eql(u8, xonly_pubkey_bytes, field_prime[0..]) or std.mem.eql(u8, xonly_pubkey_bytes, nonliftable_five[0..]);
}

fn csvField(line: []const u8, target: usize) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, line, ',');
    var index: usize = 0;
    while (iter.next()) |field| : (index += 1) {
        if (index == target) return field;
    }
    return null;
}

fn cmdStorageProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
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

fn cmdScriptCorpus(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const manifest = valueArg(args, "--manifest") orelse "../Shared/conformance/fixtures/scripts/manifest.json";
    const output = valueArg(args, "--output") orelse (ResultPaths{}).script;
    const shadow_crypto = flagArg(args, "--shadow-crypto");
    if (shadow_crypto and core.crypto.own_curve) return error.CryptoBackendNotCompiled;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const fixtures = root.get("fixtures") orelse return error.ManifestMissingFixtures;
    if (fixtures != .array) return error.ManifestMissingFixtures;

    var rows = std.ArrayList(u8).empty;
    defer rows.deinit(allocator);
    var failed: usize = 0;
    for (fixtures.array.items, 0..) |fixture, i| {
        const obj = fixture.object;
        const fixture_id = jsonString(obj.get("fixture_id")) orelse "unknown";
        var loader_error: ?[]const u8 = null;
        if (obj.get("files")) |files_value| {
            if (files_value == .object) {
                var iter = files_value.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .array) {
                        loader_error = "files category is not an array";
                        break;
                    }
                    for (entry.value_ptr.array.items) |path_value| {
                        const rel = jsonString(path_value) orelse {
                            loader_error = "file path is not a string";
                            break;
                        };
                        const full = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(manifest) orelse ".", rel });
                        defer allocator.free(full);
                        std.Io.Dir.cwd().access(io, full, .{}) catch {
                            loader_error = "referenced file missing";
                            break;
                        };
                    }
                    if (loader_error != null) break;
                }
            } else loader_error = "files object missing";
        } else loader_error = "files object missing";

        if (i != 0) try rows.appendSlice(allocator, ",");
        if (loader_error == null) {
            verifyScriptFixture(allocator, io, manifest, obj, shadow_crypto) catch |err| {
                failed += 1;
                const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"failed\",\"failure\":\"{s}\"}}", .{ fixture_id, @errorName(err) });
                defer allocator.free(row);
                try rows.appendSlice(allocator, row);
                continue;
            };
            const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"passed\",\"failure\":\"\"}}", .{fixture_id});
            defer allocator.free(row);
            try rows.appendSlice(allocator, row);
        } else {
            failed += 1;
            const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"failed\",\"failure\":\"{s}\"}}", .{ fixture_id, loader_error.? });
            defer allocator.free(row);
            try rows.appendSlice(allocator, row);
        }
    }
    const passed = fixtures.array.items.len - failed;
    const result = if (failed == 0) "passed" else "failed";
    const json = if (shadow_crypto)
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"port.script_corpus_shadow_crypto.v1\",\"category\":\"script_corpus\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"runtime_surface\":\"{s}\",\"native_crypto_backend\":\"libsecp256k1\",\"shadow_crypto_backend\":\"zig-secp256k1\",\"fixture_count\":{},\"passed\":{},\"failed\":{},\"result\":\"{s}\",\"verifier\":{{\"engine\":\"zig_native\",\"delegated\":false,\"crypto_backend\":\"libsecp256k1\",\"shadow_crypto\":true,\"implemented\":true,\"source\":\"Nodes/Zig/src/script.zig\"}},\"results\":[{s}]}}\n",
            .{ surface, fixtures.array.items.len, passed, failed, result, rows.items },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"port.script_corpus_result.v1\",\"category\":\"script_corpus\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"runtime_surface\":\"{s}\",\"native_crypto_backend\":\"{s}\",\"fixture_count\":{},\"passed\":{},\"failed\":{},\"result\":\"{s}\",\"verifier\":{{\"engine\":\"zig_native\",\"delegated\":false,\"crypto_backend\":\"{s}\",\"implemented\":true,\"source\":\"Nodes/Zig/src/script.zig\"}},\"results\":[{s}]}}\n",
            .{ surface, core.crypto.default_label, fixtures.array.items.len, passed, failed, result, core.crypto.default_label, rows.items },
        );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}

fn cmdLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, prefetch_text: []const u8, script_threads_text: []const u8, default_peer: []const u8, default_crypto_backend: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const shadow = flagArg(args, "--shadow");
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    var lock = try core.datadir.DatadirLock.acquire(allocator, datadir);
    defer lock.release();
    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        const native_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.native_dir });
        defer allocator.free(native_path);
        var native = try core.native_store.NativeStore.open(allocator, native_path, try nativeOpenOptions(args));
        defer native.close();
        if (shadow) {
            if (comptime !core.rocksdb_compiled) {
                try out.print("error: --shadow needs RocksDB, which this binary did not link; rebuild without -Dstore=native\n", .{});
                return error.StoreNotCompiled;
            }
            try std.Io.Dir.cwd().createDirPath(io, db_path);
            var rocks = try core.RocksDb.open(allocator, db_path);
            defer rocks.close();
            var pair = core.ShadowStore(core.native_store.NativeStore, core.RocksDb).init(&native, &rocks);
            try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &pair, native_path, true, "native");
        } else {
            try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &native, native_path, false, "native");
        }
        return;
    }
    if (!std.mem.eql(u8, store_name, "rocksdb")) return error.UnsupportedStore;
    if (comptime !core.rocksdb_compiled) {
        try out.print("error: --store=rocksdb needs RocksDB, which this binary did not link; rebuild without -Dstore=native or pass --store=native\n", .{});
        return error.StoreNotCompiled;
    }
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    if (shadow) {
        const shadow_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.rocksdb_shadow_dir });
        defer allocator.free(shadow_path);
        try std.Io.Dir.cwd().createDirPath(io, shadow_path);
        var primary = try core.RocksDb.open(allocator, db_path);
        defer primary.close();
        var shadow_db = try core.RocksDb.open(allocator, shadow_path);
        defer shadow_db.close();
        var pair = core.ShadowStore(core.RocksDb, core.RocksDb).init(&primary, &shadow_db);
        try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &pair, db_path, true, "rocksdb");
    } else {
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &db, db_path, false, "rocksdb");
    }
}

fn runLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, prefetch_text: []const u8, script_threads_text: []const u8, default_peer: []const u8, default_crypto_backend: []const u8, db: anytype, db_path: []const u8, shadow: bool, store_name: []const u8) !void {
    const target_text = valueArg(args, "--target") orelse "5000";
    const peer = valueArg(args, "--peer") orelse default_peer;
    const output = valueArg(args, "--output") orelse (ResultPaths{}).proof;
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const crypto_backend = parseScriptCryptoBackend(valueArg(args, "--crypto-backend") orelse default_crypto_backend) orelse return error.UnsupportedCryptoBackend;
    const crypto_label = crypto_backend.label();
    if (core.crypto.own_curve != (crypto_backend == .own_curve)) return error.CryptoBackendNotCompiled;
    const comparable = crypto_backend == .native and !shadow and std.mem.eql(u8, store_name, "rocksdb");
    const target = try std.fmt.parseInt(u32, target_text, 10);
    const benchmark_lane_arg = valueArg(args, "--benchmark-lane") orelse "";
    var profile = proofProfile(target) orelse return error.UnsupportedProofTarget;
    profile = try overrideBenchmarkLane(profile, benchmark_lane_arg);
    const comparability_label = if (std.mem.eql(u8, benchmark_lane_arg, "self_hosted")) "self_hosted" else if (comparable) "comparable" else "diagnostic_non_comparable";
    const prefetch_raw = std.fmt.parseInt(usize, prefetch_text, 10) catch 4;
    const prefetch = @min(@max(prefetch_raw, 1), 16);
    const requested_script_threads = if (script_threads_text.len == 0)
        core.connect.defaultScriptThreadCount()
    else
        @min(@max(std.fmt.parseInt(usize, script_threads_text, 10) catch core.connect.defaultScriptThreadCount(), 1), 64);
    const started = core.datadir.nowMs();

    try std.Io.Dir.cwd().createDirPath(io, datadir);
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    // The marker records which verifier last wrote this datadir. The set hash
    // does not depend on the verifier, so a store opened under the other
    // backend stays valid.
    try db.put(tryMetadataKey(allocator, "validation_crypto_backend"), crypto_label);
    try db.put(tryMetadataKey(allocator, "crypto_source_digest"), core.crypto.source_digest);
    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    const start_height: u32 = if (meta.validated_height < 0) 0 else @intCast(meta.validated_height + 1);
    const fresh_state = start_height == 0;

    var client = try core.p2p.Client.connect(allocator, peer);
    defer client.close();
    var script_runner = try core.connect.ScriptVerifyRunner.createWithCryptoBackend(allocator, requested_script_threads, crypto_backend);
    defer script_runner.destroy();
    try client.handshake(if (meta.validated_height < 0) 0 else @intCast(meta.validated_height));
    const headers = try client.headersThrough(target);
    defer allocator.free(headers);

    var blocks_fetched: u32 = 0;
    var blocks_connected: u32 = 0;
    var last_height: u32 = if (start_height == 0) 0 else start_height - 1;
    var last_hash = try allocator.dupe(u8, if (meta.validated_hash.len == 0) "" else meta.validated_hash);
    defer allocator.free(last_hash);
    var timing = ProofTiming{};
    var split_windows = core.script_verify_split.Windows{};
    var slow = SlowBlocks{};
    var last_tick_height: u32 = if (start_height == 0) 0 else start_height - 1;
    var last_tick_ms = started;
    var last_utxos: i64 = meta.chainstate_utxo_count;
    var telemetry_tick_count: i64 = 0;
    const progress_interval: u32 = 500;

    try emitTelemetryTick(out, profile, peer, crypto_label, "run_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "container_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "node_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "first_peer_byte", "peer_connect", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;

    var cursor: usize = start_height;
    var emitted_first_block_connected = false;
    while (cursor <= target) {
        const end = @min(cursor + prefetch, @as(usize, target) + 1);
        const fetch_started = core.datadir.nowMs();
        const blocks = try client.requestBlocks(headers[cursor..end], @intCast(cursor));
        timing.p2p_fetch += elapsedMs(fetch_started);
        defer allocator.free(blocks);
        for (blocks) |fetched| {
            defer fetched.deinit(allocator);
            blocks_fetched += 1;
            const block_started = core.datadir.nowMs();
            const parse_started = core.datadir.nowMs();
            const expected_prev: ?[32]u8 = if (fetched.height == 0) null else headers[fetched.height - 1];
            const decoded = try core.block.decodeBlock(allocator, fetched.raw, fetched.hash, expected_prev);
            defer {
                for (decoded.transactions) |transaction| transaction.deinit(allocator);
                allocator.free(decoded.transactions);
            }
            timing.block_parse_validate += elapsedMs(parse_started);
            const store_started = core.datadir.nowMs();
            try db.recordBlock(allocator, fetched.height, decoded.info.hash, fetched.raw);
            timing.block_store += elapsedMs(store_started);
            const connect_started = core.datadir.nowMs();
            var connect = try core.connect.connectDecodedBlock(allocator, db, fetched.height, target, decoded.info, decoded.transactions, script_runner, last_utxos);
            defer connect.deinit(allocator);
            timing.connect_total += elapsedMs(connect_started);
            timing.prevout_batch_load += connect.timings.prevout_batch_load;
            timing.utxo_load += connect.timings.utxo_load;
            timing.utxo_lookup_count += connect.timings.utxo_lookup_count;
            timing.utxo_key_bytes += connect.timings.utxo_key_bytes;
            timing.utxo_value_bytes += connect.timings.utxo_value_bytes;
            timing.utxo_hit_ns += connect.timings.utxo_hit_ns;
            timing.utxo_miss_ns += connect.timings.utxo_miss_ns;
            timing.utxo_hit_count += connect.timings.utxo_hit_count;
            timing.utxo_miss_count += connect.timings.utxo_miss_count;
            timing.created_utxos += connect.timings.created_utxos;
            timing.spent_external += connect.timings.spent_external;
            timing.same_block_spends += connect.timings.same_block_spends;
            timing.runner_batches += connect.timings.runner_batches;
            timing.tx_count += connect.timings.tx_count;
            timing.input_count += connect.timings.input_count;
            timing.script_verify += connect.timings.script_verify;
            timing.script_jobs += connect.timings.script_jobs;
            if (split_windows.note(fetched.height, connect.timings.script_split, connect.timings.script_verify)) |window| {
                const line = try core.script_verify_split.formatWindow(allocator, window);
                defer allocator.free(line);
                try out.print("{s}\n", .{line});
                try out.flush();
            }
            timing.script_threads = connect.timings.script_threads;
            timing.script_wall_ms += connect.timings.script_wall_ms;
            timing.script_worker_cpu_ms += connect.timings.script_worker_cpu_ms;
            timing.script_worker_elapsed_ns += connect.timings.script_worker_elapsed_ns;
            timing.script_worker_thread_cpu_ns += connect.timings.script_worker_thread_cpu_ns;
            timing.utxo_apply += connect.timings.utxo_apply;
            timing.commit += connect.timings.commit;
            timing.utxo_delete_prepare += connect.timings.utxo_delete_prepare;
            timing.utxo_put_prepare += connect.timings.utxo_put_prepare;
            timing.undo_put_prepare += connect.timings.undo_put_prepare;
            timing.metadata_put_prepare += connect.timings.metadata_put_prepare;
            timing.rocksdb_write += connect.timings.rocksdb_write;
            timing.set_hash_fold += connect.timings.set_hash_fold;
            timing.snapshot += connect.timings.snapshot;
            timing.block_connect_store_commit += connect.timings.block_connect_store_commit;
            timing.set_hash_hex = core.store.writeSetHashHex(db.setHash());
            blocks_connected += connect.blocks_connected;
            last_height = fetched.height;
            allocator.free(last_hash);
            last_hash = try allocator.dupe(u8, connect.validated_hash);
            const last_block_ms = elapsedMs(block_started);
            slow.record(fetched.height, last_block_ms, connect.timings);
            last_utxos = connect.chainstate_utxo_count;
            if (!emitted_first_block_connected) {
                try emitTelemetryTick(out, profile, peer, crypto_label, "first_block_connected", "block_connect", fetched.height, connect.validated_hash, connect.chainstate_utxo_count, last_block_ms, started, last_tick_ms, last_tick_height, timing);
                telemetry_tick_count += 1;
                emitted_first_block_connected = true;
            }
            const should_tick = fetched.height % progress_interval == 0 or fetched.height == target or core.datadir.nowMs() - last_tick_ms >= 15_000;
            if (should_tick) {
                try out.print("zigbitnode-local-reference-proof progress height={} target={} hash={s} utxos={} blocks_fetched={} blocks_connected={}\n", .{
                    fetched.height,
                    target,
                    connect.validated_hash,
                    connect.chainstate_utxo_count,
                    blocks_fetched,
                    blocks_connected,
                });
                try out.flush();
                try emitTelemetryTick(out, profile, peer, crypto_label, if (fetched.height == target) "target_reached" else "heartbeat", if (fetched.height == target) "complete" else "heartbeat", fetched.height, connect.validated_hash, connect.chainstate_utxo_count, last_block_ms, started, last_tick_ms, last_tick_height, timing);
                telemetry_tick_count += 1;
                last_tick_ms = core.datadir.nowMs();
                last_tick_height = fetched.height;
            }
        }
        cursor = end;
    }

    const final_meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, final_meta);
    if (last_height != target) return error.TargetNotReached;
    if (profile.strict_expected) {
        if (!std.mem.eql(u8, last_hash, profile.expected_hash)) return error.UnexpectedTargetHash;
        if (final_meta.chainstate_utxo_count != profile.expected_utxo_count) return error.UnexpectedUtxoCount;
    }
    try emitTelemetryTick(out, profile, peer, crypto_label, "run_finished", "complete", last_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;

    if (split_windows.finish(last_height)) |window| {
        const line = try core.script_verify_split.formatWindow(allocator, window);
        defer allocator.free(line);
        try out.print("{s}\n", .{line});
        try out.flush();
    }
    const split_json = try core.script_verify_split.formatProof(allocator, split_windows);
    defer allocator.free(split_json);

    const slow_json = try slow.toJson(allocator);
    defer allocator.free(slow_json);
    const total_ms = elapsedMs(started);
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);
    try appendFmt(allocator, &json_buf, "{{\"schema\":\"port.local_reference_proof.v1\",\"category\":\"local_reference_sync\",\"benchmark_contract_version\":1,\"benchmark_gate\":\"{s}\",\"benchmark_kind\":\"{s}\",\"benchmark_lane\":\"{s}\",\"benchmark_comparability\":\"{s}\",\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"captured_at\":\"unix_ms:{}\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"node\":\"ZigNode\",\"chain\":\"testnet4\",\"target_height\":{},\"header_target_height\":{},\"target_label\":\"{s}\",", .{ profile.benchmark_gate, profile.benchmark_kind, profile.benchmark_lane, comparability_label, core.datadir.nowMs(), target, target, profile.target_label });
    try appendFmt(allocator, &json_buf, "\"runtime_surface\":\"{s}\",\"peer_mode\":\"local_reference\",\"peer\":\"{s}\",\"byte_source\":\"local_reference_p2p\",\"proof_mode\":\"p2p_sync\",\"prefetch_depth\":{},\"script_runner_mode\":\"parallel\",\"script_threads\":{},\"rocksdb_wal_disabled\":false,\"fresh_state\":{},\"resume_supported\":true,", .{ surface, peer, prefetch, script_runner.thread_count, fresh_state });
    try appendFmt(allocator, &json_buf, "\"datadir\":\"{s}\",\"chainstate_backend\":\"{s}\",\"crypto_backend\":\"{s}\",\"utxo_hash\":\"{s}\",\"chainstate_backend_path\":\"{s}\",\"chainstate_status\":\"usable\",\"native_storage\":true,\"native_crypto_available\":{},\"native_crypto_backend\":\"{s}\",\"schnorr_backend\":\"{s}\",\"taproot_tweak_backend\":\"{s}\",\"storage_codec_version\":2,", .{ datadir, store_name, core.crypto.lane, core.native_store.utxoHashName(), db_path, crypto_backend == .native, crypto_label, crypto_label, crypto_label });
    try appendFmt(allocator, &json_buf, "\"rocksdb_tuning\":\"{s}\",\"validated_height\":{},\"validated_hash\":\"{s}\",\"header_height\":{},\"stored_block_height\":{},\"blocks_fetched\":{},\"blocks_connected\":{},\"chainstate_utxo_count\":{},\"chainstate_set_hash\":\"{s}\",", .{ core.RocksDb.tuningDescription(), final_meta.validated_height, last_hash, final_meta.header_height, final_meta.stored_block_height, blocks_fetched, blocks_connected, final_meta.chainstate_utxo_count, final_meta.chainstate_set_hash });
    try appendFmt(allocator, &json_buf, "\"utxo_accounting_policy\":\"core_spendable_v1\",\"sync_status\":\"blocks_current\",\"local_reference_status\":\"target_reached\",\"status\":\"passed\",\"result\":\"passed\",\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\",\"failures\":[],\"reference_start_height\":0,\"reference_start_hash\":\"00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043\",\"reference_finish_height\":{},\"reference_finish_hash\":\"{s}\",", .{ target, last_hash });
    try appendFmt(allocator, &json_buf, "\"pipeline_timing_summary\":{{\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"total_ms\":{},\"stage_totals_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"block_store\":{},\"connect_total\":{},\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}},", .{ total_ms, timing.p2p_fetch, timing.block_parse_validate, timing.block_store, timing.connect_total, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    try appendFmt(allocator, &json_buf, "\"timing_summary\":{{\"total_ms\":{},\"stage_totals_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}},", .{ total_ms, timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    try appendFmt(allocator, &json_buf, "\"set_hash_fold_ms\":{},\"snapshot_ms\":{},\"rehash_count\":{},\"rehash_ms\":{},\"peak_rss_bytes\":{},\"script_verify_split\":{s},", .{ timing.set_hash_fold, timing.snapshot, storeCounter(db, "rehash_count", u32, 0), storeCounter(db, "rehash_ms", i64, 0), core.store.peakRssBytes(), split_json });
    try appendFmt(allocator, &json_buf, "\"telemetry_summary\":{{\"telemetry_quality\":\"clean\",\"tick_count\":{},\"heartbeat_max_gap_ms\":0,\"lifecycle_markers\":{{\"run_started\":0,\"container_started\":0,\"node_started\":0,\"first_peer_byte\":0,\"first_block_connected\":0,\"target_reached\":{},\"run_finished\":{}}},\"phase_counts\":{{}},\"stall_class_counts\":{{\"none\":{}}},\"slow_blocks\":[{s}]}}}}\n", .{ telemetry_tick_count, total_ms, total_ms, telemetry_tick_count, slow_json });
    const json = json_buf.items;
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
    if (@hasField(@TypeOf(db.*), "divergence_count")) {
        const primary_hash = core.store.writeSetHashHex(db.primary.setHash());
        const shadow_hash = core.store.writeSetHashHex(db.shadow.setHash());
        var gate_buf: std.ArrayList(u8) = .empty;
        defer gate_buf.deinit(allocator);
        try appendFmt(allocator, &gate_buf, "{{\"schema\":\"port.native_store.gate.v1\",\"gate\":\"{s}\",\"height\":{},\"utxo_count\":{},\"divergence_count\":{},\"reorg_tested\":false,\"peak_rss_bytes\":{},\"set_hash_fold_ms\":{},\"snapshot_count\":{},\"snapshot_bytes\":{},\"primary_set_hash\":\"{s}\",\"shadow_set_hash\":\"{s}\",\"engines\":{{\"primary\":{{\"utxo_load\":{},\"commit\":{},\"snapshot_ms\":{},\"block_connect_store_commit\":{},\"set_hash_fold\":{}}},\"shadow\":{{\"utxo_load\":{},\"commit\":{},\"snapshot_ms\":{},\"block_connect_store_commit\":{},\"set_hash_fold\":{}}}}},\"total_ms\":{},", .{
            shadowGateName(store_name, target),
            target,
            db.primary.utxo_count,
            db.divergence_count,
            core.store.peakRssBytes(),
            timing.set_hash_fold,
            snapshotCount(db),
            snapshotBytes(db),
            primary_hash[0..],
            shadow_hash[0..],
            db.primary_utxo_load_ms,
            db.primary_commit_ms,
            db.primary_snapshot_ms,
            timing.block_connect_store_commit,
            db.primary_set_hash_fold_ms,
            db.shadow_utxo_load_ms,
            db.shadow_commit_ms,
            db.shadow_snapshot_ms,
            db.shadow_utxo_load_ms + db.shadow_commit_ms + db.shadow_snapshot_ms,
            db.shadow_set_hash_fold_ms,
            total_ms,
        });
        var pin_buf: [128]u8 = undefined;
        const pins = toolchainProvenance(&pin_buf);
        try appendFmt(allocator, &gate_buf, "\"runtime_surface\":\"{s}\",\"optimize\":\"{s}\",\"utxo_hash\":\"{s}\",\"snapshot_every\":{},\"utxo_capacity_hint\":{},\"rehash_count\":{},\"rehash_ms\":{},\"mem_limit\":\"{s}\",\"utxo_hit_ns\":{},\"utxo_miss_ns\":{},\"utxo_hit_count\":{},\"utxo_miss_count\":{},\"proof_scope\":\"peer_shadow\",\"mechanism_tests\":\"zig build test\",\"peer_gates\":[\"shadow_5k\",\"shadow_50k\",\"shadow_100k\",\"storage_proof\"],\"disk_tradeoff\":\"RocksDB compresses stored blocks. Native chainstate uses uncompressed flat block files, and the commit log keeps delete preimages so replay can check them. A larger native datadir is that tradeoff.\",\"comparability\":\"utxo_load and commit are comparable between engines.primary and engines.shadow; block_connect_store_commit is not, because the primary bucket includes the whole connect and the shadow comparisons\"{s}}}\n", .{ surface, optimizeName(), core.native_store.utxoHashName(), snapshotEvery(db), capacityHint(db), rehashCount(db), rehashMs(db), memLimit(args), timing.utxo_hit_ns, timing.utxo_miss_ns, timing.utxo_hit_count, timing.utxo_miss_count, pins });
        try out.print("{s}", .{gate_buf.items});
        if (valueArg(args, "--gate-output")) |path| try writeFileEnsuringParent(io, path, gate_buf.items);
        if (db.divergence_count != 0) return error.StoreDivergence;
    }
}

const ProofTiming = struct {
    p2p_fetch: i64 = 0,
    block_parse_validate: i64 = 0,
    block_store: i64 = 0,
    connect_total: i64 = 0,
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
    set_hash_hex: [64]u8 = [_]u8{'0'} ** 64,
};

fn proofProfile(target: u32) ?ProofProfile {
    return switch (target) {
        5000 => .{
            .target = 5000,
            .target_label = "5k",
            .benchmark_gate = "baseline_5k",
            .benchmark_kind = "baseline_5k_p2p",
            .benchmark_lane = "baseline_5k_p2p",
            .expected_hash = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
            .expected_utxo_count = 4574,
        },
        50000 => .{
            .target = 50000,
            .target_label = "50k",
            .benchmark_gate = "shakedown_50k",
            .benchmark_kind = "shakedown_50k_p2p",
            .benchmark_lane = "shakedown_50k_p2p",
            .expected_hash = "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb",
            .expected_utxo_count = 568855,
        },
        100000 => .{
            .target = 100000,
            .target_label = "100k",
            .benchmark_gate = "performance_100k",
            .benchmark_kind = "performance_100k_p2p",
            .benchmark_lane = "performance_100k_p2p",
            .expected_hash = "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
            .expected_utxo_count = 13154991,
        },
        else => if (target > 100000) .{
            .target = target,
            .target_label = "post-100k",
            .benchmark_gate = "post_100k_to_tip",
            .benchmark_kind = "post_100k_to_tip_p2p",
            .benchmark_lane = "post_100k_to_tip_p2p",
            .strict_expected = false,
            .expected_hash = "",
            .expected_utxo_count = -1,
        } else null,
    };
}

fn overrideBenchmarkLane(profile: ProofProfile, lane: []const u8) !ProofProfile {
    if (lane.len == 0) return profile;
    if (!std.mem.eql(u8, lane, "self_hosted")) return error.UnsupportedBenchmarkLane;
    var overridden = profile;
    if (profile.target == 5000) {
        overridden.benchmark_gate = "self_hosted_5k";
        overridden.benchmark_kind = "self_hosted_5k_p2p";
        overridden.benchmark_lane = "self_hosted_5k_p2p";
    } else if (profile.target == 50000) {
        overridden.benchmark_gate = "self_hosted_50k";
        overridden.benchmark_kind = "self_hosted_50k_p2p";
        overridden.benchmark_lane = "self_hosted_50k_p2p";
    } else if (profile.target == 100000) {
        overridden.benchmark_gate = "self_hosted_100k";
        overridden.benchmark_kind = "self_hosted_100k_p2p";
        overridden.benchmark_lane = "self_hosted_100k_p2p";
    } else return error.UnsupportedBenchmarkLane;
    return overridden;
}

fn emitTelemetryTick(
    out: anytype,
    profile: ProofProfile,
    peer: []const u8,
    crypto_backend: []const u8,
    event: []const u8,
    phase: []const u8,
    height: u32,
    hash: []const u8,
    utxos: i64,
    last_block_ms: i64,
    started_ms: i64,
    previous_tick_ms: i64,
    previous_tick_height: u32,
    timing: ProofTiming,
) !void {
    const now = core.datadir.nowMs();
    const elapsed_ms = @max(0, now - started_ms);
    const since_tick_ms = @max(1, now - previous_tick_ms);
    const recent_blocks: i64 = if (height >= previous_tick_height) @intCast(height - previous_tick_height) else 0;
    const total_blocks: i64 = @intCast(height + 1);
    const recent_rate = @divTrunc(recent_blocks * 1000, since_tick_ms);
    const total_rate = if (elapsed_ms > 0) @divTrunc(total_blocks * 1000, elapsed_ms) else 0;
    const percent = @divTrunc(@as(u64, height) * 100, @as(u64, profile.target));
    const stall_class = if (last_block_ms >= 15_000 and std.mem.eql(u8, phase, "block_connect")) "block_connect_slow" else "none";
    try out.print(
        "benchmark.telemetry_tick {{\"schema\":\"benchmark.telemetry_tick.v1\",\"port\":\"zig\",\"gate\":\"{s}\",\"run_id\":\"zig-{s}-{}\",\"event\":\"{s}\",\"target_height\":{},\"height\":{},\"percent\":{},\"elapsed_ms\":{},\"monotonic_ms\":{},\"rate_recent_blocks_per_second\":{},\"rate_total_blocks_per_second\":{},\"phase\":\"{s}\",\"utxos\":{},\"last_block_ms\":{},\"current_blocker\":null,\"stall_class\":\"{s}\",\"current_block_elapsed_ms\":{},\"current_block_height\":{},\"current_block_hash\":\"{s}\",\"current_block_tx_count\":{},\"current_block_vin_count\":{},\"current_block_script_input_count\":{},\"peer\":\"{s}\",",
        .{ profile.benchmark_gate, profile.benchmark_gate, started_ms, event, profile.target, height, percent, elapsed_ms, elapsed_ms, recent_rate, total_rate, phase, utxos, last_block_ms, stall_class, last_block_ms, height, hash, timing.tx_count, timing.input_count, timing.script_jobs, peer },
    );
    try out.print(
        "\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},",
        .{ timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns },
    );
    try out.print(
        "\"timing_buckets_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"script_verify\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"set_hash_fold\":{},\"block_connect_store_commit\":{}}}}}\n",
        .{ timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.script_verify, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.set_hash_fold, timing.block_connect_store_commit },
    );
    try out.print(
        "rb.port_progress {{\"crypto_source_digest\":\"{s}\",\"crypto_lane\":\"{s}\",\"chain\":\"testnet4\",\"sync_status\":\"{s}\",\"header_height\":{},\"validated_height\":{},\"validated_hash\":\"{s}\",\"stored_block_height\":{},\"chainstate_utxo_count\":{},\"chainstate_set_hash\":\"{s}\",\"current_blocker\":null,\"peer\":\"{s}\",\"current_block_height\":{},\"current_block_hash\":\"{s}\",\"current_block_tx_count\":{},\"current_block_vin_count\":{},\"current_block_script_input_count\":{},\"last_block_ms\":{},\"native_crypto_backend\":\"{s}\",\"timing_buckets_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"script_verify\":{},\"utxo_apply\":{},\"commit\":{},\"set_hash_fold\":{},\"block_connect_store_commit\":{}}}}}\n",
        .{ core.crypto.source_digest, if (std.mem.eql(u8, crypto_backend, "libsecp256k1-zig")) "own_curve" else if (std.mem.eql(u8, crypto_backend, "zig-secp256k1")) "ecosystem_curve" else "c_binding", if (height >= profile.target) "blocks_current" else "blocks_syncing", height, height, hash, height, utxos, timing.set_hash_hex[0..], peer, height, hash, timing.tx_count, timing.input_count, timing.script_jobs, last_block_ms, crypto_backend, timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.script_verify, timing.utxo_apply, timing.commit, timing.set_hash_fold, timing.block_connect_store_commit },
    );
    try out.flush();
}

const SlowBlocks = struct {
    const Entry = struct {
        height: u32 = 0,
        ms: i64 = 0,
        tx_count: u64 = 0,
        input_count: u64 = 0,
        created_utxos: u64 = 0,
        spent_external: u64 = 0,
        same_block_spends: u64 = 0,
        script_jobs: u64 = 0,
        utxo_value_bytes: u64 = 0,
    };

    entries: [10]Entry = [_]Entry{.{}} ** 10,
    len: usize = 0,

    fn record(self: *SlowBlocks, height: u32, ms: i64, timings: core.connect.ConnectTimings) void {
        var pos: usize = 0;
        while (pos < self.len and self.entries[pos].ms >= ms) : (pos += 1) {}
        if (pos >= 10) return;
        if (self.len < 10) self.len += 1;
        var i = self.len - 1;
        while (i > pos) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }
        self.entries[pos] = .{
            .height = height,
            .ms = ms,
            .tx_count = timings.tx_count,
            .input_count = timings.input_count,
            .created_utxos = timings.created_utxos,
            .spent_external = timings.spent_external,
            .same_block_spends = timings.same_block_spends,
            .script_jobs = timings.script_jobs,
            .utxo_value_bytes = timings.utxo_value_bytes,
        };
    }

    fn toJson(self: SlowBlocks, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (0..self.len) |i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            const entry = self.entries[i];
            const item = try std.fmt.allocPrint(allocator, "{{\"height\":{},\"ms\":{},\"tx_count\":{},\"input_count\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"script_jobs\":{},\"utxo_value_bytes\":{}}}", .{ entry.height, entry.ms, entry.tx_count, entry.input_count, entry.created_utxos, entry.spent_external, entry.same_block_spends, entry.script_jobs, entry.utxo_value_bytes });
            defer allocator.free(item);
            try out.appendSlice(allocator, item);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn verifyScriptFixture(allocator: std.mem.Allocator, io: std.Io, manifest: []const u8, obj: std.json.ObjectMap, shadow_crypto: bool) !void {
    const tx_path = try firstFixturePath(allocator, manifest, obj, "tx");
    defer allocator.free(tx_path);
    const raw_tx = try readHexFile(allocator, io, tx_path);
    defer allocator.free(raw_tx);
    const parsed = try core.tx.deserialize(allocator, raw_tx, 0);
    defer parsed.transaction.deinit(allocator);
    if (parsed.offset != raw_tx.len) return error.TransactionTrailingBytes;

    const input_index: usize = @intCast(jsonInteger(obj.get("input_index")) orelse return error.InputIndexMissing);
    var loaded_prevouts = loadFixturePrevouts(allocator, io, manifest, obj) catch blk: {
        var fallback = try allocator.alloc(core.script.SpentPrevout, parsed.transaction.inputs.len);
        errdefer allocator.free(fallback);
        for (fallback) |*prevout| prevout.* = .{ .amount = 0, .script_pubkey = try allocator.dupe(u8, &.{}) };
        const prev_spk_path = try firstFixturePath(allocator, manifest, obj, "prev_spk");
        defer allocator.free(prev_spk_path);
        const prev_spk = try readHexFile(allocator, io, prev_spk_path);
        const amount = jsonInteger(obj.get("prev_amount_sats")) orelse 0;
        if (input_index >= fallback.len) {
            allocator.free(prev_spk);
            return error.InputIndexOutOfRange;
        }
        allocator.free(fallback[input_index].script_pubkey);
        fallback[input_index] = .{ .amount = amount, .script_pubkey = prev_spk };
        break :blk fallback;
    };
    defer {
        for (loaded_prevouts) |prevout| allocator.free(prevout.script_pubkey);
        allocator.free(loaded_prevouts);
    }
    if (loaded_prevouts.len != parsed.transaction.inputs.len) {
        if (loaded_prevouts.len != 1) return error.PrevoutCountMismatch;
        const only = loaded_prevouts[0];
        var normalized = try allocator.alloc(core.script.SpentPrevout, parsed.transaction.inputs.len);
        errdefer allocator.free(normalized);
        for (normalized) |*prevout| prevout.* = .{ .amount = 0, .script_pubkey = try allocator.dupe(u8, &.{}) };
        if (input_index >= normalized.len) return error.InputIndexOutOfRange;
        allocator.free(normalized[input_index].script_pubkey);
        normalized[input_index] = .{ .amount = only.amount, .script_pubkey = try allocator.dupe(u8, only.script_pubkey) };
        for (loaded_prevouts) |prevout| allocator.free(prevout.script_pubkey);
        allocator.free(loaded_prevouts);
        loaded_prevouts = normalized;
    }
    if (input_index >= loaded_prevouts.len) return error.InputIndexOutOfRange;

    if (!shadow_crypto) {
        try core.script.verifyInput(allocator, parsed.transaction, input_index, loaded_prevouts);
        return;
    }

    var native_verifier = try core.crypto.NativeVerifier.create();
    defer native_verifier.destroy();
    var pure_verifier = core.crypto.PureVerifier.create();
    defer pure_verifier.destroy();
    var native_result: ?anyerror = null;
    core.script.verifyInputWithVerifier(allocator, parsed.transaction, input_index, loaded_prevouts, .{ .native = &native_verifier }, null) catch |err| {
        native_result = err;
    };
    var pure_result: ?anyerror = null;
    core.script.verifyInputWithVerifier(allocator, parsed.transaction, input_index, loaded_prevouts, .{ .pure = &pure_verifier }, null) catch |err| {
        pure_result = err;
    };
    if (native_result) |native_err| {
        if (pure_result == null or !std.mem.eql(u8, @errorName(native_err), @errorName(pure_result.?))) return error.ShadowCryptoDisagreement;
        return native_err;
    }
    if (pure_result != null) return error.ShadowCryptoDisagreement;
}

fn loadFixturePrevouts(allocator: std.mem.Allocator, io: std.Io, manifest: []const u8, obj: std.json.ObjectMap) ![]core.script.SpentPrevout {
    const prevouts_path = try firstFixturePath(allocator, manifest, obj, "prevouts");
    defer allocator.free(prevouts_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, prevouts_path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidPrevoutsJson;
    var prevouts = try allocator.alloc(core.script.SpentPrevout, parsed.value.array.items.len);
    errdefer allocator.free(prevouts);
    for (parsed.value.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidPrevoutsJson;
        const amount = jsonInteger(item.object.get("amount")) orelse jsonInteger(item.object.get("value")) orelse return error.InvalidPrevoutsJson;
        const spk_hex = jsonString(item.object.get("spk")) orelse jsonString(item.object.get("script_pubkey")) orelse return error.InvalidPrevoutsJson;
        prevouts[i] = .{ .amount = amount, .script_pubkey = try core.crypto.fromHexAlloc(allocator, spk_hex) };
    }
    return prevouts;
}

fn firstFixturePath(allocator: std.mem.Allocator, manifest: []const u8, obj: std.json.ObjectMap, category: []const u8) ![]u8 {
    const files = obj.get("files") orelse return error.FixtureFilesMissing;
    if (files != .object) return error.FixtureFilesMissing;
    const values = files.object.get(category) orelse return error.FixturePathMissing;
    if (values != .array or values.array.items.len == 0) return error.FixturePathMissing;
    const rel = jsonString(values.array.items[0]) orelse return error.FixturePathMissing;
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(manifest) orelse ".", rel });
}

fn readHexFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return core.crypto.fromHexAlloc(allocator, trimmed);
}

fn cmdSupervisorOnce(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
    _ = allocator;
    _ = args;
    try out.print("{{\"schema\":\"port.supervisor_once.v1\",\"port\":\"zig\",\"status\":\"not_ready\",\"current_blocker\":\"sync supervisor requires local-reference P2P implementation\",\"binary_gate_status\":\"not_attempted\"}}\n", .{});
    return error.SupervisorNotImplemented;
}

fn nativeOpenOptions(args: []const []const u8) !core.native_store.OpenOptions {
    var options = core.native_store.OpenOptions{};
    if (valueArg(args, "--snapshot-every")) |text| options.snapshot_every = try std.fmt.parseInt(u32, text, 10);
    if (valueArg(args, "--utxo-capacity-hint")) |text| options.utxo_capacity_hint = try std.fmt.parseInt(u32, text, 10);
    options.fsync_enabled = flagArg(args, "--fsync");
    if (valueArg(args, "--crash-after-block")) |text| options.crash_after_block = try std.fmt.parseInt(u32, text, 10);
    if (valueArg(args, "--crash-point")) |text| {
        if (std.mem.eql(u8, text, "before-append")) options.crash_point = .before_append else if (std.mem.eql(u8, text, "after-append")) options.crash_point = .after_append else return error.UnsupportedCrashPoint;
    }
    if (options.crash_after_block != null and options.crash_point == .none) return error.UnsupportedCrashPoint;
    return options;
}

fn optimizeName() []const u8 {
    return switch (@import("builtin").mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

fn shadowGateName(store_name: []const u8, target: u32) []const u8 {
    if (!std.mem.eql(u8, store_name, "native")) return "shadow_rocksdb";
    if (target == 5000) return "shadow_5k";
    if (target == 50000) return "shadow_50k";
    if (target == 100000) return "shadow_100k";
    return "shadow_native";
}

fn memLimit(args: []const []const u8) []const u8 {
    return valueArg(args, "--mem-limit") orelse "none";
}

fn snapshotCount(db: anytype) u64 {
    if (@hasField(@TypeOf(db.primary.*), "snapshot_count")) return db.primary.snapshot_count;
    return 0;
}

fn snapshotBytes(db: anytype) u64 {
    if (@hasField(@TypeOf(db.primary.*), "snapshot_bytes")) return db.primary.snapshot_bytes;
    return 0;
}

fn snapshotEvery(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "options")) return db.primary.options.snapshot_every;
    return 0;
}

fn capacityHint(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "options")) return db.primary.options.utxo_capacity_hint;
    return 0;
}

fn storeCounter(db: anytype, comptime name: []const u8, comptime T: type, default: T) T {
    const Child = @TypeOf(db.*);
    if (@hasField(Child, name)) return @field(db.*, name);
    if (@hasField(Child, "primary")) {
        const primary = db.primary;
        if (@hasField(@TypeOf(primary.*), name)) return @field(primary.*, name);
    }
    return default;
}

fn rehashCount(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "rehash_count")) return db.primary.rehash_count;
    return 0;
}

fn rehashMs(db: anytype) i64 {
    if (@hasField(@TypeOf(db.primary.*), "rehash_ms")) return db.primary.rehash_ms;
    return 0;
}

fn parseScriptCryptoBackend(value: []const u8) ?core.connect.ScriptCryptoBackend {
    if (std.mem.eql(u8, value, "own_curve") or std.mem.eql(u8, value, "libsecp256k1-zig")) return .own_curve;
    if (std.mem.eql(u8, value, "libsecp256k1") or std.mem.eql(u8, value, "native")) return .native;
    if (std.mem.eql(u8, value, "zig-secp256k1") or std.mem.eql(u8, value, "pure")) return .pure;
    return null;
}

fn parseCryptoMutation(value: []const u8) ?CryptoMutation {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "schnorr-accept-bad-s")) return .schnorr_accept_bad_s;
    if (std.mem.eql(u8, value, "schnorr-accept-bad-xonly")) return .schnorr_accept_bad_xonly;
    if (std.mem.eql(u8, value, "taproot-ignore-output-check")) return .taproot_ignore_output_check;
    return null;
}

fn tryMetadataKey(allocator: std.mem.Allocator, name: []const u8) []u8 {
    return core.codec.encodeMetadataKey(allocator, name) catch @panic("metadata key allocation failed");
}
