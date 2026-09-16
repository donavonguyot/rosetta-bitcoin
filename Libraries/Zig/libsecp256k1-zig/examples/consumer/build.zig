const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.dependency("secp256k1", .{ .target = target, .optimize = optimize }).module("secp256k1");
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "secp256k1", .module = lib }} }) });
    b.installArtifact(exe);
}
