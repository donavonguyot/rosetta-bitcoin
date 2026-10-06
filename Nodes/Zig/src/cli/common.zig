const std = @import("std");
const core = @import("zigbitnode");

pub fn elapsedMs(start_ms: i64) i64 {
    return @max(0, core.datadir.nowMs() - start_ms);
}

pub fn valueArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') return arg[name.len + 1 ..];
    }
    return null;
}

pub fn flagArg(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

pub fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

pub fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        if (v == .integer) return v.integer;
    }
    return null;
}

pub fn writeFileEnsuringParent(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        // createDirPath("/tmp") returns NotDir on this Zig. An existing parent needs no create.
        std.Io.Dir.cwd().access(io, parent, .{}) catch {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        };
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}

pub fn toolchainProvenance(buf: *[128]u8) []const u8 {
    const raw = std.c.getenv("ZIG_TOOLCHAIN_SHA256") orelse return "";
    const text = std.mem.span(raw);
    if (text.len != 64) return "";
    return std.fmt.bufPrint(buf, ",\"provenance\":{{\"toolchain_sha256\":\"{s}\"}}", .{text}) catch "";
}

pub fn appendToolchainProvenance(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    var buf: [128]u8 = undefined;
    const pins = toolchainProvenance(&buf);
    if (pins.len != 0) try out.appendSlice(allocator, pins);
}

pub fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const part = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(part);
    try out.appendSlice(allocator, part);
}

pub fn nativeOpenOptions(args: []const []const u8) !core.native_store.OpenOptions {
    var options = core.native_store.OpenOptions{};
    if (valueArg(args, "--snapshot-every")) |text| options.snapshot_every = try std.fmt.parseInt(u32, text, 10);
    if (valueArg(args, "--utxo-capacity-hint")) |text| options.utxo_capacity_hint = try std.fmt.parseInt(u32, text, 10);
    options.fsync_enabled = flagArg(args, "--fsync");
    if (valueArg(args, "--crash-after-block")) |text| options.crash_after_block = try std.fmt.parseInt(u32, text, 10);
    if (valueArg(args, "--crash-point")) |text| {
        if (std.mem.eql(u8, text, "before-append")) options.crash_point = .before_append else if (std.mem.eql(u8, text, "after-append")) options.crash_point = .after_append else return error.UnsupportedCrashPoint;
    }
    if (options.crash_after_block != null and options.crash_point == .none) return error.UnsupportedCrashPoint;
    return options;
}

pub fn optimizeName() []const u8 {
    return switch (@import("builtin").mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

pub fn parseScriptCryptoBackend(value: []const u8) ?core.connect.ScriptCryptoBackend {
    if (std.mem.eql(u8, value, "own_curve") or std.mem.eql(u8, value, "libsecp256k1-zig")) return .own_curve;
    if (std.mem.eql(u8, value, "libsecp256k1") or std.mem.eql(u8, value, "native")) return .native;
    if (std.mem.eql(u8, value, "zig-secp256k1") or std.mem.eql(u8, value, "pure")) return .pure;
    return null;
}

pub fn tryMetadataKey(allocator: std.mem.Allocator, name: []const u8) []u8 {
    return core.codec.encodeMetadataKey(allocator, name) catch @panic("metadata key allocation failed");
}
