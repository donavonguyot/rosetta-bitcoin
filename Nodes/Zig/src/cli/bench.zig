const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    const bench_args = if (args.len > 1) args[1..] else &.{};
    try @import("crypto_bench").run(allocator, init.io, out, bench_args);
}
