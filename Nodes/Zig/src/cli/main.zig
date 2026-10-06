const std = @import("std");
const Io = std.Io;
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const parseScriptCryptoBackend = common.parseScriptCryptoBackend;
const sync = @import("sync.zig");
const cmdLocalReferenceProof = sync.cmdLocalReferenceProof;
const cmdSupervisorOnce = sync.cmdSupervisorOnce;
const status = @import("status.zig");
const cmdStatus = status.cmdStatus;
const storage_proof = @import("storage_proof.zig");
const cmdStorageProof = storage_proof.cmdStorageProof;
const vectors = @import("vectors.zig");
const cmdCodecVectors = vectors.cmdCodecVectors;
const cmdNativeCrypto = vectors.cmdNativeCrypto;
const cmdTestCapability = vectors.cmdTestCapability;
const script_corpus = @import("script_corpus.zig");
const cmdScriptCorpus = script_corpus.cmdScriptCorpus;
const headers = @import("headers.zig");
const cmdCheckHeaders = headers.cmdCheckHeaders;
const context = @import("context.zig");
const cmdConsensusContext = context.cmdConsensusContext;
const cmdWriteContextFixtures = context.cmdWriteContextFixtures;
const mempool = @import("mempool.zig");
const cmdRung0 = mempool.cmdRung0;

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
        try cmdCodecVectors(allocator, out);
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
        try cmdConsensusContext(allocator, io, out, args[2..]);
    } else if (std.mem.eql(u8, command, "write-context-fixtures")) {
        try cmdWriteContextFixtures(allocator, io, out, args[2..]);
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
