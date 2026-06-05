const std = @import("std");
const crypto = @import("crypto.zig");

pub const OutPoint = struct {
    hash: [32]u8,
    index: u32,
};

pub const TxIn = struct {
    previous_output: OutPoint,
    script_sig: []const u8,
    sequence: u32,
};

pub const TxOut = struct {
    value: i64,
    script_pubkey: []const u8,
};

pub const Transaction = struct {
    version: i32,
    inputs: []TxIn,
    outputs: []TxOut,
    lock_time: u32,
    witness: []const []const []const u8,
    raw_no_witness: []const u8,

    pub fn deinit(self: Transaction, allocator: std.mem.Allocator) void {
        for (self.inputs) |input| allocator.free(input.script_sig);
        allocator.free(self.inputs);
        for (self.outputs) |output| allocator.free(output.script_pubkey);
        allocator.free(self.outputs);
        for (self.witness) |stack| {
            for (stack) |item| allocator.free(item);
            allocator.free(stack);
        }
        allocator.free(self.witness);
        allocator.free(self.raw_no_witness);
    }

    pub fn isCoinbase(self: Transaction) bool {
        if (self.inputs.len != 1) return false;
        const input = self.inputs[0];
        return input.previous_output.index == 0xffff_ffff and std.mem.allEqual(u8, input.previous_output.hash[0..], 0);
    }

    pub fn txid(self: Transaction) [32]u8 {
        return crypto.doubleSha256(self.raw_no_witness);
    }

    pub fn wtxid(self: Transaction, allocator: std.mem.Allocator) ![32]u8 {
        if (self.witness.len == 0) return self.txid();
        const raw = try serialize(allocator, self, true);
        defer allocator.free(raw);
        return crypto.doubleSha256(raw);
    }
};

pub fn readCompactSize(data: []const u8, offset_in: usize) !struct { value: u64, offset: usize } {
    var offset = offset_in;
    if (offset >= data.len) return error.TruncatedCompactSize;
    const first = data[offset];
    offset += 1;
    return switch (first) {
        0xfd => blk: {
            if (offset + 2 > data.len) return error.TruncatedCompactSize16;
            break :blk .{ .value = std.mem.readInt(u16, data[offset..][0..2], .little), .offset = offset + 2 };
        },
        0xfe => blk: {
            if (offset + 4 > data.len) return error.TruncatedCompactSize32;
            break :blk .{ .value = std.mem.readInt(u32, data[offset..][0..4], .little), .offset = offset + 4 };
        },
        0xff => blk: {
            if (offset + 8 > data.len) return error.TruncatedCompactSize64;
            break :blk .{ .value = std.mem.readInt(u64, data[offset..][0..8], .little), .offset = offset + 8 };
        },
        else => .{ .value = first, .offset = offset },
    };
}

pub fn writeCompactSize(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    if (value < 0xfd) {
        try out.append(allocator, @intCast(value));
    } else if (value <= 0xffff) {
        try out.append(allocator, 0xfd);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(value), .little);
        try out.appendSlice(allocator, &buf);
    } else if (value <= 0xffff_ffff) {
        try out.append(allocator, 0xfe);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @intCast(value), .little);
        try out.appendSlice(allocator, &buf);
    } else {
        try out.append(allocator, 0xff);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try out.appendSlice(allocator, &buf);
    }
}

pub fn deserialize(allocator: std.mem.Allocator, data: []const u8, offset_in: usize) !struct { transaction: Transaction, offset: usize } {
    var offset = offset_in;
    if (offset + 4 > data.len) return error.TruncatedTxVersion;
    const version = @as(i32, @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)));
    offset += 4;

    var witness = false;
    if (offset + 2 <= data.len and data[offset] == 0x00 and data[offset + 1] == 0x01) {
        witness = true;
        offset += 2;
    }

    const in_count_result = try readCompactSize(data, offset);
    offset = in_count_result.offset;
    const in_count: usize = @intCast(in_count_result.value);
    var inputs = try allocator.alloc(TxIn, in_count);
    errdefer {
        for (inputs[0..]) |input| allocator.free(input.script_sig);
        allocator.free(inputs);
    }
    for (inputs) |*input| {
        if (offset + 36 > data.len) return error.TruncatedTxInputOutpoint;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, data[offset..][0..32]);
        offset += 32;
        const index = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const script_len_result = try readCompactSize(data, offset);
        offset = script_len_result.offset;
        const script_len: usize = @intCast(script_len_result.value);
        if (offset + script_len > data.len) return error.TruncatedTxInputScript;
        const script_sig = try allocator.dupe(u8, data[offset..][0..script_len]);
        offset += script_len;
        if (offset + 4 > data.len) return error.TruncatedTxInputSequence;
        const sequence = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        input.* = .{
            .previous_output = .{ .hash = hash, .index = index },
            .script_sig = script_sig,
            .sequence = sequence,
        };
    }

    const out_count_result = try readCompactSize(data, offset);
    offset = out_count_result.offset;
    const out_count: usize = @intCast(out_count_result.value);
    var outputs = try allocator.alloc(TxOut, out_count);
    errdefer {
        for (outputs[0..]) |output| allocator.free(output.script_pubkey);
        allocator.free(outputs);
    }
    for (outputs) |*output| {
        if (offset + 8 > data.len) return error.TruncatedTxOutputValue;
        const value = @as(i64, @bitCast(std.mem.readInt(u64, data[offset..][0..8], .little)));
        offset += 8;
        const script_len_result = try readCompactSize(data, offset);
        offset = script_len_result.offset;
        const script_len: usize = @intCast(script_len_result.value);
        if (offset + script_len > data.len) return error.TruncatedTxOutputScript;
        const script_pubkey = try allocator.dupe(u8, data[offset..][0..script_len]);
        offset += script_len;
        output.* = .{ .value = value, .script_pubkey = script_pubkey };
    }

    const witnesses = try allocator.alloc([]const []const u8, if (witness) in_count else 0);
    errdefer allocator.free(witnesses);
    if (witness) {
        for (witnesses) |*stack_ptr| {
            const item_count_result = try readCompactSize(data, offset);
            offset = item_count_result.offset;
            const item_count: usize = @intCast(item_count_result.value);
            const stack = try allocator.alloc([]const u8, item_count);
            errdefer allocator.free(stack);
            for (stack) |*item_ptr| {
                const item_len_result = try readCompactSize(data, offset);
                offset = item_len_result.offset;
                const item_len: usize = @intCast(item_len_result.value);
                if (offset + item_len > data.len) return error.TruncatedWitnessItem;
                item_ptr.* = try allocator.dupe(u8, data[offset..][0..item_len]);
                offset += item_len;
            }
            stack_ptr.* = stack;
        }
    }

    if (offset + 4 > data.len) return error.TruncatedTxLockTime;
    const lock_time = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    const raw_no_witness = try serializePartsNoWitness(allocator, version, inputs, outputs, lock_time);
    return .{
        .transaction = .{
            .version = version,
            .inputs = inputs,
            .outputs = outputs,
            .lock_time = lock_time,
            .witness = witnesses,
            .raw_no_witness = raw_no_witness,
        },
        .offset = offset,
    };
}

pub fn serializeNoWitness(allocator: std.mem.Allocator, transaction: Transaction) ![]u8 {
    return serializePartsNoWitness(allocator, transaction.version, transaction.inputs, transaction.outputs, transaction.lock_time);
}

pub fn serialize(allocator: std.mem.Allocator, transaction: Transaction, include_witness: bool) ![]u8 {
    if (!include_witness or transaction.witness.len == 0) return serializeNoWitness(allocator, transaction);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var version_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_buf, @bitCast(transaction.version), .little);
    try out.appendSlice(allocator, &version_buf);
    try out.appendSlice(allocator, &.{ 0x00, 0x01 });
    try writeCompactSize(allocator, &out, transaction.inputs.len);
    for (transaction.inputs) |input| {
        try out.appendSlice(allocator, input.previous_output.hash[0..]);
        var index_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_buf, input.previous_output.index, .little);
        try out.appendSlice(allocator, &index_buf);
        try writeCompactSize(allocator, &out, input.script_sig.len);
        try out.appendSlice(allocator, input.script_sig);
        var seq_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_buf, input.sequence, .little);
        try out.appendSlice(allocator, &seq_buf);
    }
    try writeCompactSize(allocator, &out, transaction.outputs.len);
    for (transaction.outputs) |output| {
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, @bitCast(output.value), .little);
        try out.appendSlice(allocator, &value_buf);
        try writeCompactSize(allocator, &out, output.script_pubkey.len);
        try out.appendSlice(allocator, output.script_pubkey);
    }
    for (0..transaction.inputs.len) |i| {
        const stack = if (i < transaction.witness.len) transaction.witness[i] else &.{};
        try writeCompactSize(allocator, &out, stack.len);
        for (stack) |item| {
            try writeCompactSize(allocator, &out, item.len);
            try out.appendSlice(allocator, item);
        }
    }
    var lock_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lock_buf, transaction.lock_time, .little);
    try out.appendSlice(allocator, &lock_buf);
    return out.toOwnedSlice(allocator);
}

fn serializePartsNoWitness(
    allocator: std.mem.Allocator,
    version: i32,
    inputs: []const TxIn,
    outputs: []const TxOut,
    lock_time: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var version_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_buf, @bitCast(version), .little);
    try out.appendSlice(allocator, &version_buf);
    try writeCompactSize(allocator, &out, inputs.len);
    for (inputs) |input| {
        try out.appendSlice(allocator, input.previous_output.hash[0..]);
        var index_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_buf, input.previous_output.index, .little);
        try out.appendSlice(allocator, &index_buf);
        try writeCompactSize(allocator, &out, input.script_sig.len);
        try out.appendSlice(allocator, input.script_sig);
        var seq_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_buf, input.sequence, .little);
        try out.appendSlice(allocator, &seq_buf);
    }
    try writeCompactSize(allocator, &out, outputs.len);
    for (outputs) |output| {
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, @bitCast(output.value), .little);
        try out.appendSlice(allocator, &value_buf);
        try writeCompactSize(allocator, &out, output.script_pubkey.len);
        try out.appendSlice(allocator, output.script_pubkey);
    }
    var lock_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lock_buf, lock_time, .little);
    try out.appendSlice(allocator, &lock_buf);
    return out.toOwnedSlice(allocator);
}

pub fn parseBlockTransactions(allocator: std.mem.Allocator, raw: []const u8) ![]Transaction {
    if (raw.len < 81) return error.BlockTooShort;
    const count_result = try readCompactSize(raw, 80);
    var offset = count_result.offset;
    const count: usize = @intCast(count_result.value);
    const transactions = try allocator.alloc(Transaction, count);
    errdefer allocator.free(transactions);
    for (transactions) |*transaction| {
        const parsed = try deserialize(allocator, raw, offset);
        transaction.* = parsed.transaction;
        offset = parsed.offset;
    }
    if (offset != raw.len) return error.BlockParserTrailingBytes;
    return transactions;
}

test "parse fixture transaction and preserve txid" {
    const fixture = "0100000001ba20e5d190d9d77a48ba77f58f5677cba6c112f8f03992ba832a3eb8fd103f3a000000006b483045022100be1dadc77d8bd20bd773ceae36c956c3e4565b2177e54c1a7108f062cf80b5e20220567b468660c0a67a741d40185739f9fafde22419416ca0d9964b3988e610d83b0121025a6014b5d4317598d6f39571a07cae4ba38270c371bc7b2042271df6785c36fbffffffff0250910700000000001976a91496fecec73f25f2a1759688860d97f9f232d00c4f88ac7c0d0300000000001976a914e4e517ee07984a129f4b0b83bf3dc0cf68abc52188ac00000000";
    const raw = try crypto.fromHexAlloc(std.testing.allocator, fixture);
    defer std.testing.allocator.free(raw);
    const parsed = try deserialize(std.testing.allocator, raw, 0);
    defer parsed.transaction.deinit(std.testing.allocator);
    try std.testing.expectEqual(raw.len, parsed.offset);
    try std.testing.expectEqual(@as(usize, 1), parsed.transaction.inputs.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.transaction.outputs.len);
    const txid = parsed.transaction.txid();
    const display = try crypto.displayHashAlloc(std.testing.allocator, txid[0..]);
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings("5dbe8b5407d550c49f3fec0cd0d21fe130b7edec8e0e2af099556d0c239115e0", display);
}
