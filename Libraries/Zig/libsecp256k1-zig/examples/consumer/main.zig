const std = @import("std");
const secp = @import("secp256k1");
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.Usage;
    var b: [3][]u8 = undefined;
    for (&b, 0..) |*v, i| {
        v.* = try allocator.alloc(u8, args[i + 2].len / 2);
        _ = try std.fmt.hexToBytes(v.*, args[i + 2]);
    }
    var buffer: [256]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &writer.interface;
    defer out.flush() catch {};
    var malformed = false;
    var ok = false;
    if (std.mem.eql(u8, args[1], "ecdsa")) {
        ok = secp.verifyEcdsa(b[0], b[1], b[2]) catch blk: {
            malformed = true;
            break :blk false;
        };
    } else if (std.mem.eql(u8, args[1], "schnorr")) {
        ok = secp.verifySchnorr(b[0], b[1], b[2]) catch blk: {
            malformed = true;
            break :blk false;
        };
    } else if (std.mem.eql(u8, args[1], "tweak")) {
        const r = secp.addXOnlyTweak(b[0], b[1]) catch {
            try out.writeAll("malformed_input\n");
            return;
        };
        try out.print("{s}:{d}\n", .{ std.fmt.bytesToHex(r.output_xonly, .lower), r.parity });
        return;
    } else return error.UnknownOperation;
    try out.print("{s}\n", .{if (malformed) "malformed_input" else if (ok) "valid" else "consensus_invalid"});
}
