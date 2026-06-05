const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("zigbitnode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addNativeDeps(core_mod, target);

    const exe = b.addExecutable(.{
        .name = "zigbitnode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbitnode", .module = core_mod },
            },
        }),
    });
    addNativeDeps(exe.root_module, target);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zigbitnode");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = core_mod });
    addNativeDeps(tests.root_module, target);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ZigNode tests");
    test_step.dependOn(&run_tests.step);
}

fn addNativeDeps(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    module.link_libc = true;
    module.linkSystemLibrary("rocksdb", .{});
    module.linkSystemLibrary("secp256k1", .{});
    if (target.result.os.tag == .macos) {
        module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
}
