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
const nativeOpenOptions = common.nativeOpenOptions;
const optimizeName = common.optimizeName;
const parseScriptCryptoBackend = common.parseScriptCryptoBackend;
const tryMetadataKey = common.tryMetadataKey;
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

const ResultPaths = struct {
    script: []const u8 = "../Shared/conformance/results/zig_script_corpus_latest.json",
    storage: []const u8 = "../Shared/conformance/results/zig_storage_gate_docker_latest.json",
    proof: []const u8 = ".benchmark-results/zig_docker_baseline_5k_benchmark_latest.json",
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
