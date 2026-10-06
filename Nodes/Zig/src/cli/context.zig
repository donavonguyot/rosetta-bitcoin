//! `consensus-context` writes the must-reject corpus result.
//! The gate is the consensus-context host proof.
//! Does not retarget. `consensus_context.zig` does.

const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const valueArg = common.valueArg;

/// consensus-context gate. Writes the must-reject corpus result.
pub fn cmdConsensusContext(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    const default_manifest = try common.joinFixtures(allocator, "conformance/fixtures/consensus/context/manifest.json");
    defer allocator.free(default_manifest);
    const manifest = valueArg(args, "--manifest") orelse default_manifest;
    const ok = try core.context_fixture.runManifest(allocator, io, manifest, out);
    if (!ok) return error.ConsensusContextFailed;
}

/// Writes the consensus-context fixtures the corpus gate reads.
pub fn cmdWriteContextFixtures(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    if (comptime !core.rocksdb_compiled) return error.StoreNotCompiled;
    const datadir = valueArg(args, "--datadir") orelse return error.MissingDatadir;
    const out_dir = valueArg(args, "--out") orelse return error.MissingOutput;
    const db_path = try std.fs.path.join(allocator, &.{ datadir, "chainstate-rocksdb" });
    defer allocator.free(db_path);
    var db = try core.RocksDb.open(allocator, db_path);
    defer db.close();
    try core.context_fixture.writeBlockFixtures(allocator, io, &db, out_dir);
    try out.print("{{\"schema\":\"port.consensus_context.v1\",\"command\":\"write-context-fixtures\",\"passed\":true}}\n", .{});
}
