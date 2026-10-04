//! One copy of transaction finality, BIP68, and testnet4 nBits / BIP94.
//! Block connect, header ingest, templates, and the mempool all call these.

const std = @import("std");
const chain_params = @import("chain_params.zig");
const tx = @import("tx.zig");

pub const HeaderFields = struct {
    time: u32,
    bits: u32,
};

pub fn fieldsFromHeader(header: *const [80]u8) HeaderFields {
    return .{
        .time = std.mem.readInt(u32, header[68..72], .little),
        .bits = std.mem.readInt(u32, header[72..76], .little),
    };
}

pub fn txNotFinal(transaction: tx.Transaction, height: u32, mtp: u32, block_time: u32) bool {
    if (transaction.lock_time == 0) return false;
    if (allSequencesFinal(transaction)) return false;
    if (transaction.lock_time < chain_params.locktime_threshold) return transaction.lock_time >= height;
    const limit = if (height >= chain_params.bip113_height) mtp else block_time;
    return transaction.lock_time >= limit;
}

fn allSequencesFinal(transaction: tx.Transaction) bool {
    for (transaction.inputs) |input| if (input.sequence != 0xffffffff) return false;
    return true;
}

/// `coin_time` is the MTP of `max(coin_height - 1, 0)`. Same-block spends use
/// `coin_height == block_height` and the MTP of `block_height - 1`.
pub fn sequenceLockUnsatisfied(
    version: i32,
    sequence: u32,
    coin_height: u32,
    coin_time: u32,
    block_height: u32,
    block_mtp: u32,
) bool {
    if (block_height < chain_params.csv_height) return false;
    if (version < 2) return false;
    if ((sequence & 0x80000000) != 0) return false;
    const masked: u32 = sequence & 0x0000ffff;
    if ((sequence & 0x00400000) != 0) {
        const need = @as(u64, masked) * 512;
        const age: u64 = if (block_mtp > coin_time) block_mtp - coin_time else 0;
        return age < need;
    }
    const age: u32 = if (block_height > coin_height) block_height - coin_height else 0;
    return age < masked;
}

/// Median of up to 11 header timestamps ending at `height`. `source.headerAt`
/// returns the 80-byte header, or null when the chain has not reached it.
pub fn medianTimePast(source: anytype, height: u32) !u32 {
    var times: [11]u32 = undefined;
    var count: usize = 0;
    var cursor: i64 = height;
    while (count < 11 and cursor >= 0) : (cursor -= 1) {
        const header = (try source.headerAt(@intCast(cursor))) orelse break;
        times[count] = fieldsFromHeader(&header).time;
        count += 1;
    }
    if (count == 0) return 0;
    std.mem.sort(u32, times[0..count], {}, std.sort.asc(u32));
    return times[count / 2];
}

pub fn requiredBits(source: anytype, height: u32, time: u32) !u32 {
    if (height == 0) return chain_params.pow_limit_bits;
    const prev = try source.header(height - 1);
    if (height % chain_params.interval != 0) {
        if (@as(i64, time) > @as(i64, prev.time) + chain_params.min_difficulty_gap) {
            return chain_params.pow_limit_bits;
        }
        var cursor: u32 = height - 1;
        var bits = prev.bits;
        while (cursor > 0 and cursor % chain_params.interval != 0 and bits == chain_params.pow_limit_bits) {
            cursor -= 1;
            bits = (try source.header(cursor)).bits;
        }
        return bits;
    }
    const first = try source.header(height - chain_params.interval);
    return retargetBits(first.bits, first.time, prev.time);
}

pub fn timewarpViolation(height: u32, time: u32, prev_time: u32) bool {
    if (height == 0 or height % chain_params.interval != 0) return false;
    return @as(i64, time) < @as(i64, prev_time) - @as(i64, chain_params.timewarp);
}

pub fn timewarpFloor(prev_time: u32) u32 {
    if (prev_time > chain_params.timewarp) return prev_time - chain_params.timewarp;
    return 0;
}

pub fn clampedHeaderTime(mtp: u32, now: u32, height: u32, prev_time: u32) u32 {
    var stamp = @max(mtp +% 1, now);
    if (height % chain_params.interval == 0 and height > 0) {
        const floor = timewarpFloor(prev_time);
        if (stamp < floor) stamp = floor;
    }
    return stamp;
}

pub fn retargetBits(first_bits: u32, first_time: u32, prev_time: u32) !u32 {
    const raw: i64 = @as(i64, prev_time) - @as(i64, first_time);
    const span = std.math.clamp(raw, @divTrunc(chain_params.timespan, 4), chain_params.timespan * 4);
    const base = try compactTargetLe(first_bits);
    const limit = try compactTargetLe(chain_params.pow_limit_bits);
    const scaled = mulDiv256(base, @intCast(span), @intCast(chain_params.timespan));
    const capped = if (greaterLe(scaled, limit)) limit else scaled;
    return compactFromTarget(capped);
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

fn compactFromTarget(target: [32]u8) u32 {
    var n_size: usize = 32;
    while (n_size > 0 and target[n_size - 1] == 0) n_size -= 1;
    var compact: u32 = 0;
    if (n_size <= 3) {
        var low: u32 = 0;
        var i: usize = 0;
        while (i < n_size) : (i += 1) low |= @as(u32, target[i]) << @intCast(8 * i);
        if (n_size < 3) compact = low << @intCast(8 * (3 - n_size));
        if (n_size == 3) compact = low;
        if (n_size == 0) compact = 0;
    } else {
        const start = n_size - 3;
        compact = @as(u32, target[start]) | (@as(u32, target[start + 1]) << 8) | (@as(u32, target[start + 2]) << 16);
    }
    if ((compact & 0x00800000) != 0) {
        compact >>= 8;
        n_size += 1;
    }
    compact |= @as(u32, @intCast(n_size)) << 24;
    return compact;
}

fn mulDiv256(target: [32]u8, numer: u64, denom: u64) [32]u8 {
    var product = [_]u8{0} ** 48;
    var carry: u128 = 0;
    for (target, 0..) |byte, i| {
        const wide = @as(u128, byte) * numer + carry;
        product[i] = @truncate(wide);
        carry = wide >> 8;
    }
    var extra: usize = 32;
    while (carry > 0 and extra < product.len) : (extra += 1) {
        product[extra] = @truncate(carry);
        carry >>= 8;
    }
    var rem: u128 = 0;
    var out = [_]u8{0} ** 48;
    var j: usize = product.len;
    while (j > 0) {
        j -= 1;
        rem = (rem << 8) | product[j];
        out[j] = @intCast(rem / denom);
        rem %= denom;
    }
    return out[0..32].*;
}

fn greaterLe(left: [32]u8, right: [32]u8) bool {
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (left[i] > right[i]) return true;
        if (left[i] < right[i]) return false;
    }
    return false;
}
