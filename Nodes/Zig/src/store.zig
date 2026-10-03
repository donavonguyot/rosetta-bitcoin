const std = @import("std");
const builtin = @import("builtin");

pub const SetHash = [32]u8;

pub fn emptySetHash() SetHash {
    return [_]u8{0} ** 32;
}

/// Order-independent set hash. XOR is its own inverse, so the same call
/// folds a UTXO in or out. MuHash3072 is the Core-parity upgrade; this POC
/// does not implement it.
pub fn foldSetHash(set_hash: *SetHash, key: []const u8, value: []const u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    hasher.update(value);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    for (set_hash, digest) |*slot, byte| slot.* ^= byte;
}

pub fn formatSetHash(allocator: std.mem.Allocator, set_hash: SetHash) ![]u8 {
    return allocator.dupe(u8, &writeSetHashHex(set_hash));
}

pub fn writeSetHashHex(set_hash: SetHash) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (set_hash, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn parseSetHashHex(hex: []const u8) !SetHash {
    if (hex.len != 64) return error.InvalidSetHash;
    var out: SetHash = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return out;
}

pub fn rawEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// `ru_maxrss` is bytes on macOS and kilobytes on Linux.
pub fn peakRssBytes() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return switch (builtin.os.tag) {
        .linux => raw * 1024,
        else => raw,
    };
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidSetHash,
    };
}

pub fn nowMs() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}
