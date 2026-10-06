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
    const curve_profile = b.option(bool, "curve-profile", "Count own_curve field and group operations") orelse false;
    options.addOption(bool, "curve_profile", curve_profile);
    const source_commit = b.option([]const u8, "source-commit", "Git commit of the measured binary") orelse "unrecorded";
    options.addOption([]const u8, "source_commit", source_commit);
    const utxo_hash = b.option([]const u8, "utxo-hash", "txid64, txid64_mix, or wyhash") orelse "txid64_mix";
    if (!std.mem.eql(u8, utxo_hash, "txid64") and !std.mem.eql(u8, utxo_hash, "txid64_mix") and !std.mem.eql(u8, utxo_hash, "wyhash")) @panic("unknown utxo-hash");
    options.addOption([]const u8, "utxo_hash", utxo_hash);
    const store = b.option([]const u8, "store", "rocksdb, native, or both") orelse "both";
    if (!std.mem.eql(u8, store, "rocksdb") and !std.mem.eql(u8, store, "native") and !std.mem.eql(u8, store, "both")) @panic("unknown store");
    options.addOption([]const u8, "store", store);
    options.addOption(bool, "store_rocksdb", !std.mem.eql(u8, store, "native"));
    const shared_root = b.option([]const u8, "shared-root", "Shared tree") orelse b.pathResolve(&.{ "..", "Shared" });
    const fixtures_root = b.option([]const u8, "fixtures-root", "Fixture tree laid out like Shared") orelse shared_root;
    options.addOption([]const u8, "shared_root", shared_root);
    options.addOption([]const u8, "fixtures_root", fixtures_root);
    // Field and group code is its own module at ReleaseFast. The node keeps
    // the caller's mode (ReleaseSafe for benches). Vectors, mutations, and
    // the package property tests are the safety net for this module.
    const secp = b.dependency("secp256k1", .{ .target = target, .optimize = .ReleaseFast, .curve_profile = curve_profile }).module("secp256k1");

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
            .root_source_file = b.path("src/cli/main.zig"),
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

    const bench_options = b.addOptions();
    bench_options.addOption(bool, "own_curve", false);
    bench_options.addOption(bool, "probe", false);
    bench_options.addOption([]const u8, "reject", "");
    bench_options.addOption([]const u8, "source_digest", "unrecorded");
    bench_options.addOption(bool, "curve_profile", curve_profile);
    bench_options.addOption([]const u8, "source_commit", source_commit);
    bench_options.addOption([]const u8, "utxo_hash", "txid64_mix");
    bench_options.addOption([]const u8, "store", "native");
    bench_options.addOption(bool, "store_rocksdb", false);
    bench_options.addOption([]const u8, "shared_root", shared_root);
    bench_options.addOption([]const u8, "fixtures_root", fixtures_root);
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_core.addOptions("crypto_options", bench_options);
    bench_core.addImport("secp256k1", secp);
    addNativeDeps(bench_core, target, false, false);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigbitnode", .module = bench_core },
            .{ .name = "secp256k1", .module = secp },
        },
    });
    addNativeDeps(bench_mod, target, false, false);
    const bench_exe = b.addExecutable(.{
        .name = "zigbitnode-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "crypto_bench", .module = bench_mod },
            },
        }),
    });
    addNativeDeps(bench_exe.root_module, target, false, false);
    const bench_step = b.step("bench", "Build the c_binding crypto bench with own_curve alongside");
    bench_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

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
    const guard = b.addSystemCommand(&.{ "sh", "scripts/check_no_external_paths.sh" });
    guard.setCwd(b.path("."));
    test_step.dependOn(&guard.step);
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
    addNativeDeps(mempool_tests.root_module, target, own_curve, !std.mem.eql(u8, store, "native"));
    test_step.dependOn(&b.addRunArtifact(mempool_tests).step);

    const context_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/consensus_context.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigbitnode", .module = core_mod },
            },
        }),
    });
    context_tests.root_module.addOptions("crypto_options", options);
    context_tests.root_module.addImport("secp256k1", secp);
    addNativeDeps(context_tests.root_module, target, own_curve, !std.mem.eql(u8, store, "native"));
    test_step.dependOn(&b.addRunArtifact(context_tests).step);
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
