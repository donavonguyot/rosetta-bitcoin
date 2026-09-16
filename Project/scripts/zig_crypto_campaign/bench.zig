const std = @import("std");
const secp = @import("secp256k1");
fn decode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const b = try a.alloc(u8, s.len / 2);
    return std.fmt.hexToBytes(b, s);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("testdata/native.json"), .{});
    const vectors = parsed.value.object.get("vectors").?.array.items;
    const v = vectors[0].object;
    const key = try decode(a, v.get("pubkey_hex").?.string);
    const msg = try decode(a, v.get("msg_hash_hex").?.string);
    const sig = try decode(a, v.get("signature_hex").?.string);
    var sk: []const u8 = undefined;
    var sm: []const u8 = undefined;
    var ss: []const u8 = undefined;
    for (vectors) |item| {
        const o = item.object;
        if (std.mem.eql(u8, o.get("operation").?.string, "verify_schnorr") and std.mem.eql(u8, o.get("expected").?.string, "valid")) {
            sk = try decode(a, o.get("xonly_pubkey_hex").?.string);
            sm = try decode(a, o.get("msg_hash_hex").?.string);
            ss = try decode(a, o.get("signature_hex").?.string);
            break;
        }
    }
    const bad_s = try decode(a, "3026020101022100fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
    const inputs = Inputs{ .key = key, .msg = msg, .sig = sig, .sk = sk, .sm = sm, .ss = ss, .bad_s = bad_s };
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &writer.interface;
    defer out.flush() catch {};
    const names = [_][]const u8{ "ecdsa/valid", "ecdsa/late_invalid", "schnorr/valid", "schnorr/late_invalid", "parse/valid", "parse/early_invalid", "tweak/valid", "tweak/early_invalid", "ecdsa/scalar_early_invalid" };
    const expected = [_]bool{ true, false, true, false, true, false, true, false, false };
    for (names, 0..) |_, op| if (operation(inputs, op) != expected[op]) return error.BenchmarkCaseMismatch;
    for (0..5) |repeat| {
        for (names, 0..) |name, op| {
            const start = std.Io.Clock.awake.now(init.io).nanoseconds;
            for (0..1024) |_| std.mem.doNotOptimizeAway(operation(inputs, op));
            const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
            try out.print("{{\"operation\":\"{s}\",\"repetition\":{d},\"iterations\":1024,\"total_ns\":{d}}}\n", .{ name, repeat, elapsed });
        }
    }
}
const Inputs = struct { key: []const u8, msg: []const u8, sig: []const u8, sk: []const u8, sm: []const u8, ss: []const u8, bad_s: []const u8 };
noinline fn operation(i: Inputs, op: usize) bool {
    const zero = [_]u8{0} ** 32;
    return switch (op) {
        0 => secp.verifyEcdsa(i.key, i.msg, i.sig) catch false,
        1 => secp.verifyEcdsa(i.key, &zero, i.sig) catch false,
        2 => secp.verifySchnorr(i.sk, i.sm, i.ss) catch false,
        3 => secp.verifySchnorr(i.sk, &.{0}, i.ss) catch false,
        4 => blk: {
            const key = secp.parsePublicKey(i.key) catch break :blk false;
            std.mem.doNotOptimizeAway(key);
            break :blk true;
        },
        5 => blk: {
            const key = secp.parsePublicKey(&.{0}) catch break :blk false;
            std.mem.doNotOptimizeAway(key);
            break :blk true;
        },
        6 => blk: {
            const tweak = secp.addXOnlyTweak(i.key[1..], i.msg) catch break :blk false;
            std.mem.doNotOptimizeAway(tweak);
            break :blk true;
        },
        7 => blk: {
            const tweak = secp.addXOnlyTweak(i.key[1..], &.{0}) catch break :blk false;
            std.mem.doNotOptimizeAway(tweak);
            break :blk true;
        },
        else => secp.verifyEcdsa(i.key, i.msg, i.bad_s) catch false,
    };
}
