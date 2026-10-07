//! Order-independent UTXO set hash: XOR of SHA256(key || value).
//! Order does not matter, so two engines can be compared. That is enough for a differential
//! oracle and not enough for adversarial parity. MuHash is the Core-parity upgrade and is not implemented.
//! The value bytes are `codec.encodeUtxoValue`, not a second layout
//! (test "set hash fold is its own inverse", test "codec v2 golden vectors").
//! Does not open a database or decide a spend.

const std = @import("std");
const builtin = @import("builtin");

/// 32-byte XOR fold. The zero hash is the empty set.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub const SetHash = [32]u8;

/// What one `disconnectTip` removed. The set hash is the recorded H−1 value when it matches.
/// The block bytes stay on disk. Only the committed tip moves back.
/// test "disconnect restores the recorded set hash"
pub const DisconnectResult = struct {
    height: u32,
    block_hash: [32]u8,
    new_tip_hash: [32]u8,
    utxos_removed: u32,
    utxos_restored: u32,
    set_hash_after: SetHash,
};

/// The all-zero set hash. Folding every member of a set returns here.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn emptySetHash() SetHash {
    return [_]u8{0} ** 32;
}

/// Order-independent set hash. XOR is its own inverse, so the same call
/// folds a UTXO in or out. MuHash3072 is the Core-parity upgrade and is not
/// implemented.
/// test "set hash fold is its own inverse"
pub fn foldSetHash(set_hash: *SetHash, key: []const u8, value: []const u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    hasher.update(value);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    for (set_hash, digest) |*slot, byte| slot.* ^= byte;
}

/// Allocated hex of a set hash for a gate that needs an owned string.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn formatSetHash(allocator: std.mem.Allocator, set_hash: SetHash) ![]u8 {
    return allocator.dupe(u8, &writeSetHashHex(set_hash));
}

/// 64 lowercase hex chars of a set hash, on the stack.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn writeSetHashHex(set_hash: SetHash) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (set_hash, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

/// Parse 64 hex chars into a set hash. Any other length is refused.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn parseSetHashHex(hex: []const u8) !SetHash {
    if (hex.len != 64) return error.InvalidSetHash;
    var out: SetHash = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return out;
}

/// Byte equality that treats two missing values as equal.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn rawEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// `ru_maxrss` is bytes on macOS and kilobytes on Linux.
/// test "set hash fold is its own inverse"
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

/// Process clock in milliseconds for stage timings.
/// Folding the same key and value twice returns the previous digest.
/// test "set hash fold is its own inverse"
pub fn nowMs() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}
