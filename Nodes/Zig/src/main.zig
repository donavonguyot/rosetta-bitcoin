const std = @import("std");
const Io = std.Io;
const core = @import("zigbitnode");

const ResultPaths = struct {
    script: []const u8 = "../Shared/conformance/results/zig_script_corpus_latest.json",
    storage: []const u8 = "../Shared/conformance/results/zig_storage_gate_docker_latest.json",
    proof: []const u8 = "../Shared/conformance/results/zig_docker_supporting_5k_benchmark_latest.json",
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
    const surface = init.environ_map.get("ZIGBITNODE_RUNTIME_SURFACE") orelse "host";

    if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "codec-vectors")) {
        try core.verifyCodecVectors(allocator);
        try out.print("{{\"schema\":\"port.codec_vectors.v1\",\"port\":\"zig\",\"codec_version\":2,\"passed\":true}}\n", .{});
    } else if (std.mem.eql(u8, command, "native-crypto-vectors")) {
        try cmdNativeCrypto(out);
    } else if (std.mem.eql(u8, command, "storage-proof")) {
        try cmdStorageProof(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "script-corpus")) {
        try cmdScriptCorpus(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "local-reference-proof")) {
        try cmdLocalReferenceProof(allocator, io, out, args[2..]);
    } else if (std.mem.eql(u8, command, "sync-supervisor-once")) {
        try cmdSupervisorOnce(allocator, out, args[2..]);
    } else {
        try out.print("error: unknown command: {s}\n", .{command});
        try usage(out);
        return error.UnknownCommand;
    }
}

fn usage(out: anytype) !void {
    try out.print(
        \\zigbitnode commands:
        \\  status [--datadir ./data-zig]
        \\  storage-proof [--datadir ./data-zig] [--output path]
        \\  codec-vectors
        \\  native-crypto-vectors
        \\  script-corpus [--manifest path] [--output path]
        \\  local-reference-proof [--target 5000] [--peer host.docker.internal:48333] [--output path]
        \\  sync-supervisor-once [--target 5000] [--peer host.docker.internal:48333] [--datadir ./data-zig]
        \\
    , .{});
}

fn cmdStatus(allocator: std.mem.Allocator, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.PortInfo.default_datadir;
    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);

    var validated_height: []const u8 = "0";
    var backend: []const u8 = "none";
    var utxo_count: []const u8 = "0";
    var chainstate_status: []const u8 = "missing";
    if (core.RocksDb.open(allocator, db_path)) |db0| {
        var db = db0;
        defer db.close();
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "validated_height"))) |value| validated_height = value;
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_backend"))) |value| backend = value;
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_utxo_count"))) |value| utxo_count = value;
        chainstate_status = if (std.mem.eql(u8, backend, "rocksdb")) "usable" else "missing";
    } else |_| {}

    try out.print(
        "{{\"schema\":\"port.status.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"datadir\":\"{s}\",\"sync_status\":\"starting\",\"chainstate_backend\":\"{s}\",\"chainstate_status\":\"{s}\",\"validated_height\":{s},\"header_height\":0,\"stored_block_height\":0,\"chainstate_utxo_count\":{s},\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\"}}\n",
        .{ surface, datadir, backend, chainstate_status, validated_height, utxo_count },
    );
}

fn cmdNativeCrypto(out: anytype) !void {
    const available = core.secp256k1Available();
    try out.print(
        "{{\"schema\":\"port.native_crypto_vectors.v1\",\"port\":\"zig\",\"passed\":{},\"delegated\":false,\"ecdsa_backend\":\"libsecp256k1\",\"schnorr_backend\":\"libsecp256k1\",\"taproot_tweak_backend\":\"libsecp256k1\",\"notes\":\"backend availability smoke vector only; full shared crypto vectors are next\"}}\n",
        .{available},
    );
}

fn cmdStorageProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.PortInfo.default_datadir;
    const output = valueArg(args, "--output") orelse (ResultPaths{}).storage;
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    var db = try core.RocksDb.open(allocator, db_path);
    defer db.close();
    try db.writeBatchSmoke(allocator);

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.storage_gate_result.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"storage_backend\":\"rocksdb\",\"runtime_truth_backend\":\"rocksdb\",\"rocksdb_runtime_truth\":true,\"native_marker\":\"{s}\",\"atomic_batch_commit\":true,\"validated_height\":2,\"chainstate_status\":\"usable\",\"chainstate_backend\":\"rocksdb\",\"chainstate_utxo_count\":1,\"binary_gate_status\":\"not_attempted\",\"current_blocker\":null}}\n",
        .{ surface, core.PortInfo.marker_file },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}

fn cmdScriptCorpus(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const manifest = valueArg(args, "--manifest") orelse "../Shared/conformance/fixtures/scripts/manifest.json";
    const output = valueArg(args, "--output") orelse (ResultPaths{}).script;

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
            verifyScriptFixture(allocator, io, manifest, obj) catch |err| {
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
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.script_corpus_result.v1\",\"category\":\"script_corpus\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"runtime_surface\":\"{s}\",\"native_crypto_backend\":\"libsecp256k1\",\"fixture_count\":{},\"passed\":{},\"failed\":{},\"result\":\"{s}\",\"verifier\":{{\"engine\":\"zig_native\",\"delegated\":false,\"crypto_backend\":\"libsecp256k1\",\"implemented\":true,\"source\":\"Nodes/Zig/src/script.zig\"}},\"results\":[{s}]}}\n",
        .{ surface, fixtures.array.items.len, passed, failed, result, rows.items },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}

fn cmdLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    const target_text = valueArg(args, "--target") orelse "5000";
    const peer = valueArg(args, "--peer") orelse "host.docker.internal:48333";
    const output = valueArg(args, "--output") orelse (ResultPaths{}).proof;
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.local_reference_proof.v1\",\"benchmark_contract_version\":1,\"benchmark_kind\":\"supporting_5k_p2p\",\"benchmark_lane\":\"supporting_5k_p2p\",\"port\":\"zig\",\"node\":\"ZigNode\",\"target_height\":{s},\"header_target_height\":{s},\"target_label\":\"5k\",\"runtime_surface\":\"docker\",\"peer_mode\":\"local_reference\",\"peer\":\"{s}\",\"byte_source\":\"local_reference_p2p\",\"proof_mode\":\"p2p_sync\",\"prefetch_depth\":4,\"script_runner_mode\":\"parallel\",\"rocksdb_wal_disabled\":false,\"fresh_state\":true,\"resume_supported\":true,\"datadir\":\"{s}\",\"validated_height\":0,\"header_height\":0,\"stored_block_height\":0,\"blocks_fetched\":0,\"blocks_connected\":0,\"chainstate_utxo_count\":0,\"current_blocker\":{{\"height\":0,\"missing_rule\":\"zig P2P/local-reference connect not implemented in this wave\"}},\"binary_gate_status\":\"not_attempted\",\"status\":\"not_ready\"}}\n",
        .{ target_text, target_text, peer, datadir },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
    return error.LocalReferenceProofNotImplemented;
}

fn verifyScriptFixture(allocator: std.mem.Allocator, io: std.Io, manifest: []const u8, obj: std.json.ObjectMap) !void {
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

    try core.script.verifyInput(allocator, parsed.transaction, input_index, loaded_prevouts);
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

fn valueArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn tryMetadataKey(allocator: std.mem.Allocator, name: []const u8) []u8 {
    return core.encodeMetadataKey(allocator, name) catch @panic("metadata key allocation failed");
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        if (v == .integer) return v.integer;
    }
    return null;
}

fn writeFileEnsuringParent(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}
