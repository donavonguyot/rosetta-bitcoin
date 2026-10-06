//! Entry for `zigbitnode-bench`. The node binary does not link this command.
//! crypto-bench is the gate. The C binding and own_curve run in one process.
//! Does not connect blocks.

const std = @import("std");

/// crypto-bench: paired own_curve and libsecp timings. Not a node subcommand.
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
