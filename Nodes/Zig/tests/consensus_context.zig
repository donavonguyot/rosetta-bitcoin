const std = @import("std");
const core = @import("zigbitnode");

const context = core.consensus_context;
const params = core.chain_params;

const SliceHeaders = struct {
    items: []const context.HeaderFields,
    pub fn header(self: @This(), height: u32) !context.HeaderFields {
        if (height >= self.items.len) return error.MissingHeader;
        return self.items[height];
    }
};

const TimeHeaders = struct {
    times: []const u32,
    pub fn headerAt(self: @This(), height: u32) !?[80]u8 {
        if (height >= self.times.len) return null;
        var header = [_]u8{0} ** 80;
        std.mem.writeInt(u32, header[68..72], self.times[height], .little);
        return header;
    }
};

fn oneInput(allocator: std.mem.Allocator, version: i32, sequence: u32, lock_time: u32) !core.tx.Transaction {
    const inputs = try allocator.alloc(core.tx.TxIn, 1);
    inputs[0] = .{
        .previous_output = .{ .hash = [_]u8{0} ** 32, .index = 0 },
        .script_sig = &.{},
        .sequence = sequence,
    };
    return .{
        .version = version,
        .inputs = inputs,
        .outputs = &.{},
        .lock_time = lock_time,
        .witness = &.{},
        .raw_no_witness = &.{},
    };
}

fn fillRetarget(headers: []context.HeaderFields, first_bits: u32, first_time: u32, prev_bits: u32, prev_time: u32) void {
    for (headers, 0..) |*header, index| {
        header.* = .{ .time = first_time +% @as(u32, @intCast(index)), .bits = first_bits };
    }
    headers[0] = .{ .time = first_time, .bits = first_bits };
    headers[headers.len - 1] = .{ .time = prev_time, .bits = prev_bits };
}

test "median time past uses the headers that exist" {
    const times = [_]u32{ 30, 10, 20 };
    const median = try context.medianTimePast(TimeHeaders{ .times = &times }, 2);
    try std.testing.expectEqual(@as(u32, 20), median);
}

test "nLockTime at the block height is not final" {
    const allocator = std.testing.allocator;
    const height: u32 = 100;
    const below = try oneInput(allocator, 2, 0xfffffffe, height - 1);
    defer allocator.free(below.inputs);
    const at = try oneInput(allocator, 2, 0xfffffffe, height);
    defer allocator.free(at.inputs);
    const locked = try oneInput(allocator, 2, 0xffffffff, height);
    defer allocator.free(locked.inputs);
    try std.testing.expect(!context.txNotFinal(below, height, 50, 50));
    try std.testing.expect(context.txNotFinal(at, height, 50, 50));
    try std.testing.expect(!context.txNotFinal(locked, height, 50, 50));
}

test "BIP68 skips version 1 and the disable bit" {
    const height: u32 = 100;
    try std.testing.expect(!context.sequenceLockUnsatisfied(1, 1, height, 0, height, 0));
    try std.testing.expect(!context.sequenceLockUnsatisfied(2, 0x80000001, height, 0, height, 0));
    try std.testing.expect(!context.sequenceLockUnsatisfied(2, 1, height, 0, 0, 0));
}

test "a same-block height lock needs a zero relative lock to pass" {
    const height: u32 = 100;
    const mtp: u32 = 1_000_000;
    try std.testing.expect(context.sequenceLockUnsatisfied(2, 1, height, mtp, height, mtp));
    try std.testing.expect(!context.sequenceLockUnsatisfied(2, 0, height, mtp, height, mtp));
}

test "BIP68 time compares age with the masked 512-second lock" {
    const coin_time: u32 = 1_000;
    try std.testing.expect(context.sequenceLockUnsatisfied(2, 0x00400001, 1, coin_time, 10, coin_time + 511));
    try std.testing.expect(!context.sequenceLockUnsatisfied(2, 0x00400001, 1, coin_time, 10, coin_time + 512));
}

test "retarget clamps at both bounds" {
    const allocator = std.testing.allocator;
    const headers = try allocator.alloc(context.HeaderFields, params.interval);
    defer allocator.free(headers);
    const first_time: u32 = 1_000_000;
    const quarter: u32 = @intCast(@divTrunc(params.timespan, 4));
    const wide: u32 = @intCast(params.timespan * 4);
    const source = SliceHeaders{ .items = headers };

    fillRetarget(headers, params.pow_limit_bits, first_time, params.pow_limit_bits, first_time + quarter);
    const at_quarter = try context.requiredBits(source, params.interval, 0);
    fillRetarget(headers, params.pow_limit_bits, first_time, params.pow_limit_bits, first_time + 1);
    const at_tiny = try context.requiredBits(source, params.interval, 0);
    try std.testing.expectEqual(at_quarter, at_tiny);

    fillRetarget(headers, params.pow_limit_bits, first_time, params.pow_limit_bits, first_time + wide);
    const at_wide = try context.requiredBits(source, params.interval, 0);
    fillRetarget(headers, params.pow_limit_bits, first_time, params.pow_limit_bits, first_time + wide + params.timespan);
    const at_huge = try context.requiredBits(source, params.interval, 0);
    try std.testing.expectEqual(at_wide, at_huge);
}

test "min-difficulty walks back and does not wrap the twenty-minute gap" {
    const allocator = std.testing.allocator;
    const headers = try allocator.alloc(context.HeaderFields, params.interval + 2);
    defer allocator.free(headers);
    const ancestor_bits: u32 = 0x1d00fffe;
    for (headers, 0..) |*header, index| {
        header.* = .{ .time = 1_000_000 + @as(u32, @intCast(index)), .bits = params.pow_limit_bits };
    }
    headers[params.interval].bits = ancestor_bits;
    headers[params.interval + 1].bits = params.pow_limit_bits;
    headers[params.interval + 1].time = headers[params.interval].time + 600;
    const source = SliceHeaders{ .items = headers };
    const height = params.interval + 2;
    const walked = try context.requiredBits(source, height, headers[params.interval + 1].time + 600);
    try std.testing.expectEqual(ancestor_bits, walked);
    const easy = try context.requiredBits(source, height, headers[params.interval + 1].time + 1201);
    try std.testing.expectEqual(params.pow_limit_bits, easy);

    headers[params.interval + 1].time = 0xfffffff0;
    headers[params.interval + 1].bits = ancestor_bits;
    const near_wrap = try context.requiredBits(source, height, 0x1000);
    try std.testing.expectEqual(ancestor_bits, near_wrap);
}

test "retarget uses the first block bits" {
    const allocator = std.testing.allocator;
    const headers = try allocator.alloc(context.HeaderFields, params.interval);
    defer allocator.free(headers);
    const first_time: u32 = 1_000_000;
    const prev_time: u32 = first_time + @as(u32, @intCast(params.timespan));
    const alt: u32 = 0x1d00fffe;
    const source = SliceHeaders{ .items = headers };

    fillRetarget(headers, alt, first_time, params.pow_limit_bits, prev_time);
    const from_alt = try context.requiredBits(source, params.interval, 0);
    fillRetarget(headers, alt, first_time, 0x1c00ffff, prev_time);
    const prev_ignored = try context.requiredBits(source, params.interval, 0);
    try std.testing.expectEqual(from_alt, prev_ignored);
    fillRetarget(headers, params.pow_limit_bits, first_time, params.pow_limit_bits, prev_time);
    const from_limit = try context.requiredBits(source, params.interval, 0);
    try std.testing.expect(from_alt != from_limit);
}

test "timewarp allows exactly six hundred seconds and rejects one more" {
    const prev: u32 = 1_000_000;
    try std.testing.expect(!context.timewarpViolation(params.interval, prev - params.timewarp, prev));
    try std.testing.expect(context.timewarpViolation(params.interval, prev - params.timewarp - 1, prev));
    try std.testing.expect(!context.timewarpViolation(params.interval - 1, prev - params.timewarp - 1, prev));
    try std.testing.expect(!context.timewarpViolation(0, 0, 100));
}
