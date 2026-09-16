//! Test-only bounded JSONL consumer. Imports only the public package API.
const std = @import("std");
const secp = @import("secp256k1");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.Usage;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(16 * 1024 * 1024));
    if (data.len == 0 or data[data.len-1] != '\n') return error.TruncatedChunk;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &writer.interface;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        if (count > 1024 or line.len > 16384) return error.ChunkLimit;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        const obj = parsed.value.object;
        const id = obj.get("id").?.integer;
        const op = obj.get("op").?.string;
        var b: [3][]u8 = undefined;
        for ([_][]const u8{"key","message","signature"},0..) |field,i| {
            const hex = obj.get(field).?.string;
            b[i] = try a.alloc(u8,hex.len/2);
            _ = try std.fmt.hexToBytes(b[i],hex);
        }
        var malformed = false;
        var ok = false;
        if (std.mem.eql(u8,op,"ecdsa")) {
            ok = secp.verifyEcdsa(b[0],b[1],b[2]) catch blk: { malformed=true; break :blk false; };
        } else if (std.mem.eql(u8,op,"schnorr")) {
            ok = secp.verifySchnorr(b[0],b[1],b[2]) catch blk: { malformed=true; break :blk false; };
        } else if (std.mem.eql(u8,op,"tweak")) {
            const r = secp.addXOnlyTweak(b[0],b[1]) catch {
                try out.print("{{\"id\":{d},\"result\":\"malformed_input\"}}\n",.{id});
                continue;
            };
            try out.print("{{\"id\":{d},\"result\":\"{s}:{d}\"}}\n",.{id,std.fmt.bytesToHex(r.output_xonly,.lower),r.parity});
            continue;
        } else return error.UnknownOperation;
        try out.print("{{\"id\":{d},\"result\":\"{s}\"}}\n",.{id,if(malformed) "malformed_input" else if(ok) "valid" else "consensus_invalid"});
    }
    try out.flush();
}
