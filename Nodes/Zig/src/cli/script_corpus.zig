//! Shared script corpus runner.
//! The gate is script-corpus. Pure crypto is refused for this command.
//! Does not add templates the corpus does not already name.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const flagArg = common.flagArg;
const jsonString = common.jsonString;
const jsonInteger = common.jsonInteger;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const toolchainProvenance = common.toolchainProvenance;

/// script-corpus gate.
pub fn cmdScriptCorpus(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const default_manifest = try common.joinFixtures(allocator, "conformance/fixtures/scripts/manifest.json");
    defer allocator.free(default_manifest);
    const default_output = try common.joinShared(allocator, "conformance/results/zig_script_corpus_latest.json");
    defer allocator.free(default_output);
    const manifest = valueArg(args, "--manifest") orelse default_manifest;
    const output = valueArg(args, "--output") orelse default_output;
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
