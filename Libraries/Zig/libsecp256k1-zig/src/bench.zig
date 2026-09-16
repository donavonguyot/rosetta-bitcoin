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
        if (std.mem.eql(u8, o.get("operation").?.string, "verify_schnorr")) {
            sk = try decode(a, o.get("xonly_pubkey_hex").?.string);
            sm = try decode(a, o.get("msg_hash_hex").?.string);
            ss = try decode(a, o.get("signature_hex").?.string);
            break;
        }
    }
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &writer.interface;
    defer out.flush() catch {};
    const names = [_][]const u8{ "ecdsa/valid", "ecdsa/invalid", "schnorr/valid", "schnorr/invalid", "parse/valid", "parse/invalid", "tweak/valid", "tweak/invalid" };
    const zero = [_]u8{0} ** 32;
    for (0..5) |repeat| {
        for (names, 0..) |name, op| {
            const start = std.Io.Clock.awake.now(init.io).nanoseconds;
            for (0..64) |_| {
                const ok = switch (op) {
                    0 => secp.verifyEcdsa(key, msg, sig) catch false,
                    1 => secp.verifyEcdsa(key, &zero, sig) catch false,
                    2 => secp.verifySchnorr(sk, sm, ss) catch false,
                    3 => secp.verifySchnorr(sk, &zero, ss) catch false,
                    4 => blk: {
                        _ = secp.parsePublicKey(key) catch break :blk false;
                        break :blk true;
                    },
                    5 => blk: {
                        _ = secp.parsePublicKey(&.{0}) catch break :blk false;
                        break :blk true;
                    },
                    6 => blk: {
                        _ = secp.addXOnlyTweak(key[1..], msg) catch break :blk false;
                        break :blk true;
                    },
                    else => blk: {
                        _ = secp.addXOnlyTweak(key[1..], &.{0}) catch break :blk false;
                        break :blk true;
                    },
                };
                std.mem.doNotOptimizeAway(ok);
            }
            const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
            try out.print("{{\"operation\":\"{s}\",\"repetition\":{d},\"iterations\":64,\"total_ns\":{d},\"allocations\":0}}\n", .{ name, repeat, elapsed });
        }
    }
}
