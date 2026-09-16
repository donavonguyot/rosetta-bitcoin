const std = @import("std");
const secp = @import("root.zig");
fn decode(hex: []const u8) ![]u8 {
    const out = try std.testing.allocator.alloc(u8, hex.len / 2);
    errdefer std.testing.allocator.free(out);
    return try std.fmt.hexToBytes(out, hex);
}
fn string(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return v.string;
}
fn bytes(obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    return decode(string(obj, key));
}
test "all shared native crypto vectors with structured results" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("testdata/native.json"), .{});
    defer parsed.deinit();
    const vectors = parsed.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(33, vectors.len);
    for (vectors) |item| {
        const obj = item.object;
        const op = string(obj, "operation");
        var malformed = false;
        var ok = false;
        const key = try bytes(obj, if (std.mem.eql(u8, op, "verify_ecdsa")) "pubkey_hex" else "xonly_pubkey_hex");
        defer std.testing.allocator.free(key);
        const msg = try bytes(obj, "msg_hash_hex");
        defer std.testing.allocator.free(msg);
        const sig = try bytes(obj, "signature_hex");
        defer std.testing.allocator.free(sig);
        if (std.mem.eql(u8, op, "verify_ecdsa")) {
            ok = secp.verifyEcdsa(key, msg, sig) catch blk: {
                malformed = true;
                break :blk false;
            };
        } else if (std.mem.eql(u8, op, "verify_schnorr")) {
            ok = secp.verifySchnorr(key, msg, sig) catch blk: {
                malformed = true;
                break :blk false;
            };
        } else if (std.mem.eql(u8, op, "taproot_tweak_xonly")) {
            const root = try bytes(obj, "merkle_root_hex");
            defer std.testing.allocator.free(root);
            const Sha = std.crypto.hash.sha2.Sha256;
            var tag: [32]u8 = undefined;
            Sha.hash("TapTweak", &tag, .{});
            var h = Sha.init(.{});
            h.update(&tag);
            h.update(&tag);
            h.update(key);
            h.update(root);
            var tweak: [32]u8 = undefined;
            h.final(&tweak);
            const result = secp.addXOnlyTweak(key, &tweak) catch blk: {
                malformed = true;
                break :blk secp.TweakResult{ .output_xonly = @splat(0), .parity = 0 };
            };
            if (!malformed) {
                const expected = try bytes(obj, "expected_output_xonly_hex");
                defer std.testing.allocator.free(expected);
                ok = std.mem.eql(u8, expected, &result.output_xonly) and result.parity == obj.get("expected_parity").?.integer;
            }
        } else return error.UnhandledOperation;
        const got = if (malformed) "malformed_input" else if (ok) "valid" else "consensus_invalid";
        if (!std.mem.eql(u8, got, string(obj, "expected"))) {
            std.debug.print("fixture {s}: got {s}\n", .{ string(obj, "id"), got });
            return error.UnexpectedResult;
        }
    }
}
test "all BIP340 vectors" {
    var lines = std.mem.splitScalar(u8, @embedFile("testdata/bip340.csv"), '\n');
    _ = lines.next();
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ',');
        _ = fields.next();
        _ = fields.next();
        const key = try decode(fields.next().?);
        defer std.testing.allocator.free(key);
        _ = fields.next();
        const msg = try decode(fields.next().?);
        defer std.testing.allocator.free(msg);
        const sig = try decode(fields.next().?);
        defer std.testing.allocator.free(sig);
        const expected = std.mem.eql(u8, fields.next().?, "TRUE");
        const ok = secp.verifySchnorr(key, msg, sig) catch false;
        try std.testing.expectEqual(expected, ok);
        count += 1;
    }
    try std.testing.expectEqual(19, count);
}
test "tweak boundaries and infinity" {
    const key = try decode("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798");
    defer std.testing.allocator.free(key);
    const zero = [_]u8{0} ** 32;
    const result = try secp.addXOnlyTweak(key, &zero);
    try std.testing.expectEqualSlices(u8, key, &result.output_xonly);
    try std.testing.expectEqual(0, result.parity);
    const order = try decode("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
    defer std.testing.allocator.free(order);
    try std.testing.expectError(error.InvalidScalar, secp.addXOnlyTweak(key, order));
    order[31] -= 1;
    try std.testing.expectError(error.Infinity, secp.addXOnlyTweak(key, order));
    try std.testing.expectError(error.MalformedInput, secp.checkXOnlyTweak(key, &zero, key, 2));
}

test "hybrid parity, canonical DER scalars and low-S normalization" {
    const key = try decode("0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8");
    defer std.testing.allocator.free(key);
    _ = try secp.parsePublicKey(key);
    key[0] = 6;
    _ = try secp.parsePublicKey(key);
    key[0] = 7;
    try std.testing.expectError(error.MalformedInput, secp.parsePublicKey(key));
    key[0] = 4;
    const zero = [_]u8{0} ** 32;
    for ([_][]const u8{ "3006020100020101", "3006020180020101" }) |text| {
        const sig = try decode(text);
        defer std.testing.allocator.free(sig);
        try std.testing.expect(!try secp.verifyEcdsa(key, &zero, sig));
    }
    const high = try decode("3045022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798022100a1dc3b8e6933781adc2049d3a49bb2435842447fa73e783dda3dd8a7c6a90d5d");
    defer std.testing.allocator.free(high);
    const low = try secp.normalizeLowS(high);
    const again = try secp.normalizeLowS(low.slice());
    try std.testing.expectEqualSlices(u8, low.slice(), again.slice());
    try std.testing.expectEqual(70, low.len);
}
