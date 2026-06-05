const std = @import("std");
const crypto = @import("crypto.zig");
const tx = @import("tx.zig");

pub const BlockInfo = struct {
    hash: [32]u8,
    prev_hash: [32]u8,
    merkle_root: [32]u8,
    tx_count: usize,
    bits: u32,
};

pub fn decodeBlock(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected_hash: ?[32]u8,
    expected_prev: ?[32]u8,
) !struct { info: BlockInfo, transactions: []tx.Transaction } {
    if (raw.len < 81) return error.BlockTooShort;
    const header = raw[0..80];
    const hash = crypto.doubleSha256(header);
    if (expected_hash) |expected| {
        if (!std.mem.eql(u8, hash[0..], expected[0..])) return error.BlockHashMismatch;
    }
    var prev: [32]u8 = undefined;
    @memcpy(&prev, header[4..36]);
    if (expected_prev) |expected| {
        if (!std.mem.eql(u8, prev[0..], expected[0..])) return error.BlockPrevMismatch;
    }
    const bits = std.mem.readInt(u32, header[72..76], .little);
    if (!checkProofOfWork(hash, bits)) return error.BlockPowInvalid;
    const transactions = try tx.parseBlockTransactions(allocator, raw);
    errdefer {
        for (transactions) |transaction| transaction.deinit(allocator);
        allocator.free(transactions);
    }
    var txids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(txids);
    for (transactions, 0..) |transaction, i| txids[i] = transaction.txid();
    const merkle = try merkleRoot(allocator, txids);
    if (!std.mem.eql(u8, merkle[0..], header[36..68])) return error.BlockMerkleMismatch;
    return .{
        .info = .{ .hash = hash, .prev_hash = prev, .merkle_root = merkle, .tx_count = transactions.len, .bits = bits },
        .transactions = transactions,
    };
}

pub fn merkleRoot(allocator: std.mem.Allocator, txids: []const [32]u8) ![32]u8 {
    if (txids.len == 0) return error.EmptyMerkleTree;
    var level = try allocator.dupe([32]u8, txids);
    defer allocator.free(level);
    var len = level.len;
    while (len > 1) {
        var write: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += 2) {
            const right = if (i + 1 < len) level[i + 1] else level[i];
            var pair: [64]u8 = undefined;
            @memcpy(pair[0..32], level[i][0..]);
            @memcpy(pair[32..64], right[0..]);
            level[write] = crypto.doubleSha256(pair[0..]);
            write += 1;
        }
        len = write;
    }
    return level[0];
}

pub fn checkProofOfWork(hash_internal: [32]u8, bits: u32) bool {
    const target = compactTargetLe(bits) catch return false;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (hash_internal[i] < target[i]) return true;
        if (hash_internal[i] > target[i]) return false;
    }
    return true;
}

fn compactTargetLe(bits: u32) ![32]u8 {
    const exponent: usize = @intCast(bits >> 24);
    const mantissa = bits & 0x007f_ffff;
    if ((bits & 0x0080_0000) != 0 or mantissa == 0) return error.InvalidCompactTarget;
    var target = [_]u8{0} ** 32;
    const mantissa_bytes = [_]u8{
        @intCast((mantissa >> 16) & 0xff),
        @intCast((mantissa >> 8) & 0xff),
        @intCast(mantissa & 0xff),
    };
    if (exponent <= 3) {
        var value = mantissa >> @intCast(8 * (3 - exponent));
        var index: usize = 0;
        while (value > 0 and index < 32) : (index += 1) {
            target[index] = @intCast(value & 0xff);
            value >>= 8;
        }
    } else {
        const start = exponent - 3;
        if (start + 3 > 32) return error.TargetOverflow;
        target[start] = mantissa_bytes[2];
        target[start + 1] = mantissa_bytes[1];
        target[start + 2] = mantissa_bytes[0];
    }
    return target;
}

test "merkle root duplicates odd leaf" {
    const one = [_]u8{1} ** 32;
    const root = try merkleRoot(std.testing.allocator, &.{one});
    try std.testing.expectEqualSlices(u8, one[0..], root[0..]);
}
