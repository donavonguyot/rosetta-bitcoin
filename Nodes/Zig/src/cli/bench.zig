const std = @import("std");

pub fn cmdCryptoBench(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    try @import("crypto_bench").run(allocator, io, out, args);
}
