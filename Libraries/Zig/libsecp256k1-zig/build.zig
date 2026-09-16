const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("secp256k1", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run self-contained verification tests").dependOn(&run.step);
    const bench = b.addExecutable(.{ .name = "secp-bench", .root_module = b.createModule(.{ .root_source_file = b.path("src/bench.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "secp256k1", .module = mod }} }) });
    b.step("bench", "Benchmark public operations").dependOn(&b.addRunArtifact(bench).step);
}
