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
    try validateWitnessCommitment(allocator, transactions);
    return .{
        .info = .{ .hash = hash, .prev_hash = prev, .merkle_root = merkle, .tx_count = transactions.len, .bits = bits },
        .transactions = transactions,
    };
}

fn validateWitnessCommitment(allocator: std.mem.Allocator, transactions: []const tx.Transaction) !void {
    if (transactions.len == 0) return error.EmptyBlock;
    var has_witness = false;
    for (transactions) |transaction| {
        for (transaction.witness) |stack| {
            if (stack.len != 0) {
                has_witness = true;
                break;
            }
        }
        if (has_witness) break;
    }
    if (!has_witness) return;

    const coinbase = transactions[0];
    if (coinbase.witness.len == 0 or coinbase.witness[0].len == 0 or coinbase.witness[0][0].len != 32) {
        return error.InvalidCoinbaseWitnessReservedValue;
    }
    const reserved = coinbase.witness[0][0];
    var expected: ?[]const u8 = null;
    for (coinbase.outputs) |output| {
        const script = output.script_pubkey;
        if (script.len >= 38 and
            script[0] == 0x6a and
            script[1] == 0x24 and
            script[2] == 0xaa and
            script[3] == 0x21 and
            script[4] == 0xa9 and
            script[5] == 0xed)
        {
            expected = script[6..38];
        }
    }
    const commitment = expected orelse return error.MissingWitnessCommitment;
    var wtxids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(wtxids);
    wtxids[0] = [_]u8{0} ** 32;
    for (transactions[1..], 1..) |transaction, i| {
        wtxids[i] = try transaction.wtxid(allocator);
    }
    const root = try merkleRoot(allocator, wtxids);
    var payload: [64]u8 = undefined;
    @memcpy(payload[0..32], root[0..]);
    @memcpy(payload[32..64], reserved);
    const actual = crypto.doubleSha256(payload[0..]);
    if (!std.mem.eql(u8, actual[0..], commitment)) return error.WitnessCommitmentMismatch;
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
