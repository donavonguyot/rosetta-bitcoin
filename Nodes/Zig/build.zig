const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option([]const u8, "crypto-backend", "c_binding or own_curve") orelse "c_binding";
    if (!std.mem.eql(u8, backend, "c_binding") and !std.mem.eql(u8, backend, "own_curve")) @panic("unknown crypto-backend");
    const own_curve = std.mem.eql(u8, backend, "own_curve");
    const options = b.addOptions();
    options.addOption(bool, "own_curve", own_curve);
    const probe = b.option(bool, "crypto-probe", "Test-only crypto call tracing") orelse false;
    const reject = b.option([]const u8, "crypto-reject", "Test-only primitive rejection") orelse "";
    if (reject.len > 0 and !probe) @panic("crypto-reject requires crypto-probe");
    options.addOption(bool, "probe", probe);
    options.addOption([]const u8, "reject", reject);
    options.addOption([]const u8, "source_digest", b.option([]const u8, "crypto-source-digest", "Package source SHA256") orelse "unrecorded");
    const utxo_hash = b.option([]const u8, "utxo-hash", "txid64, txid64_mix, or wyhash") orelse "txid64_mix";
    if (!std.mem.eql(u8, utxo_hash, "txid64") and !std.mem.eql(u8, utxo_hash, "txid64_mix") and !std.mem.eql(u8, utxo_hash, "wyhash")) @panic("unknown utxo-hash");
    options.addOption([]const u8, "utxo_hash", utxo_hash);
    const store = b.option([]const u8, "store", "rocksdb, native, or both") orelse "both";
    if (!std.mem.eql(u8, store, "rocksdb") and !std.mem.eql(u8, store, "native") and !std.mem.eql(u8, store, "both")) @panic("unknown store");
    options.addOption([]const u8, "store", store);
    options.addOption(bool, "store_rocksdb", !std.mem.eql(u8, store, "native"));
    const secp = b.dependency("secp256k1", .{ .target = target, .optimize = optimize }).module("secp256k1");

    const core_mod = b.addModule("zigbitnode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addOptions("crypto_options", options);
    core_mod.addImport("secp256k1", secp);
    addNativeDeps(core_mod, target, own_curve, !std.mem.eql(u8, store, "native"));

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
    exe.root_module.addOptions("crypto_options", options);
    exe.root_module.addImport("secp256k1", secp);
    addNativeDeps(exe.root_module, target, own_curve, !std.mem.eql(u8, store, "native"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zigbitnode");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = core_mod });
    addNativeDeps(tests.root_module, target, own_curve, !std.mem.eql(u8, store, "native"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ZigNode tests");
    test_step.dependOn(&run_tests.step);

    const native_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_store.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbitnode", .module = core_mod },
            },
        }),
    });
    native_store_tests.root_module.addOptions("crypto_options", options);
    native_store_tests.root_module.addImport("secp256k1", secp);
    addNativeDeps(native_store_tests.root_module, target, own_curve, !std.mem.eql(u8, store, "native"));
    test_step.dependOn(&b.addRunArtifact(native_store_tests).step);

    const mempool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mempool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbitnode", .module = core_mod },
            },
        }),
    });
    mempool_tests.root_module.addOptions("crypto_options", options);
    mempool_tests.root_module.addImport("secp256k1", secp);
    addNativeDeps(mempool_tests.root_module, target, own_curve);
    test_step.dependOn(&b.addRunArtifact(mempool_tests).step);
}

fn addNativeDeps(module: *std.Build.Module, target: std.Build.ResolvedTarget, own_curve: bool, link_rocksdb: bool) void {
    module.link_libc = true;
    if (link_rocksdb) module.linkSystemLibrary("rocksdb", .{});
    if (!own_curve) module.linkSystemLibrary("secp256k1", .{});
    if (target.result.os.tag == .macos) {
        module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
}
