const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;
const jsonString = common.jsonString;
const jsonInteger = common.jsonInteger;
const appendFmt = common.appendFmt;
const writeFileEnsuringParent = common.writeFileEnsuringParent;

pub fn cmdNativeCrypto(out: anytype) !void {
    const available = core.crypto_glue.secp256k1Available();
    try out.print(
        "{{\"schema\":\"port.native_crypto_vectors.v1\",\"port\":\"zig\",\"passed\":{},\"delegated\":false,\"ecdsa_backend\":\"{s}\",\"schnorr_backend\":\"{s}\",\"taproot_tweak_backend\":\"{s}\",\"notes\":\"backend availability smoke vector only; full shared crypto vectors are next\"}}\n",
        .{ available, core.crypto.default_label, core.crypto.default_label, core.crypto.default_label },
    );
}

pub fn cmdTestCapability(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
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

fn parseCryptoMutation(value: []const u8) ?CryptoMutation {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "schnorr-accept-bad-s")) return .schnorr_accept_bad_s;
    if (std.mem.eql(u8, value, "schnorr-accept-bad-xonly")) return .schnorr_accept_bad_xonly;
    if (std.mem.eql(u8, value, "taproot-ignore-output-check")) return .taproot_ignore_output_check;
    return null;
}
