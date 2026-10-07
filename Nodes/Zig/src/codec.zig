//! Chainstate codec v2 key and value bytes shared with the other ports.
//! `encodeUtxoValue` is the canonical value the set-hash fold hashes. A different layout is a different set.
//! Proved by test "codec v2 golden vectors".
//! Does not interpret scripts or decide which UTXO is spent.

const std = @import("std");
const types = @import("types.zig");

const Outpoint = types.Outpoint;
const StoredUtxo = types.StoredUtxo;
const UndoEntry = types.UndoEntry;

/// Golden codec v2 hex the port must reproduce byte for byte.
/// Each field is one key or value, not a decoded UTXO.
/// test "codec v2 golden vectors"
pub const CodecVectors = struct {
    /// Golden hex for a UTXO key: prefix `u`, chain name, txid, vout.
    /// A key does not decode to a UTXO. The value hex is a different constant.
    /// test "scratch utxo key encoding matches codec vector"
    pub const utxo_key_hex = "7508746573746e657434000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000001";
    /// Golden hex for a UTXO value: height, satoshis, coinbase flag, script.
    /// These are the bytes the set-hash fold hashes. decodeUtxoValue reads them back.
    /// test "codec v2 golden vectors"
    pub const utxo_value_hex = "00000001000000012a05f200010000001976a914000102030405060708090a0b0c0d0e0f1011121388ac";
    /// Golden hex for an undo key: prefix `d` and a height.
    /// The undo payload is encodeUndoValue, not this key.
    /// test "codec v2 golden vectors"
    pub const undo_key_hex = "6408746573746e65743400000002";
    /// Golden hex for the tip key: prefix `t` and the chain name, no height.
    /// The tip value is a separate encoding of height and block hash.
    /// test "codec v2 golden vectors"
    pub const tip_key_hex = "7408746573746e657434";
    /// Golden hex for a block-index key: prefix `b` and a height.
    /// The indexed value is the display hash, not a UTXO.
    /// test "codec v2 golden vectors"
    pub const block_index_key_hex = "6208746573746e65743400000002";
    /// Golden hex for a header key: prefix `h` and a height.
    /// The stored value is the 80-byte header.
    /// test "codec v2 golden vectors"
    pub const header_key_hex = "6808746573746e65743400000002";
    /// Golden hex for a metadata key: prefix `m` and the field name.
    /// No chain id. The value is the metadata string.
    /// test "codec v2 golden vectors"
    pub const metadata_key_hex = "6d0d636f6465635f76657273696f6e";
};

/// Allocate the `u` key for one outpoint. The set hash updates with this key.
/// The paired value is encodeUtxoValue. Chain names over 252 bytes are refused.
/// test "scratch utxo key encoding matches codec vector"
pub fn encodeUtxoKey(allocator: std.mem.Allocator, chain: []const u8, outpoint: Outpoint) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try encodeUtxoKeyInto(allocator, &bytes, chain, outpoint);
    return bytes.toOwnedSlice(allocator);
}

/// Write the `u` key into the caller buffer.
/// The write is the key only. The buffer grows by encodedUtxoKeyLen.
/// test "scratch utxo key encoding matches codec vector"
pub fn encodeUtxoKeyInto(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), chain: []const u8, outpoint: Outpoint) !void {
    try bytes.append(allocator, 'u');
    try appendVarBytes(allocator, bytes, chain);
    try bytes.appendSlice(allocator, outpoint.txid[0..]);
    try appendU32Be(allocator, bytes, outpoint.vout);
}

/// Byte length of a `u` key: tag, chain length, chain, 32-byte txid, vout.
/// Chain names longer than 252 bytes are refused before any write.
/// test "scratch utxo key encoding matches codec vector"
pub fn encodedUtxoKeyLen(chain: []const u8) !usize {
    if (chain.len > 252) return error.ValueTooLarge;
    return 1 + 1 + chain.len + 32 + 4;
}

/// Canonical UTXO value: height, satoshis, coinbase flag, script.
/// The set-hash fold hashes these bytes and no other layout.
/// test "codec v2 golden vectors"
pub fn encodeUtxoValue(allocator: std.mem.Allocator, utxo: StoredUtxo) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, utxo.height);
    try appendU64Be(allocator, &bytes, utxo.value_sats);
    try bytes.append(allocator, if (utxo.coinbase) 1 else 0);
    try appendVarBytes32(allocator, &bytes, utxo.script_pubkey);
    return bytes.toOwnedSlice(allocator);
}

/// Key for the undo of one height, prefix `d`.
/// The payload under this key is encodeUndoValue.
/// test "codec v2 golden vectors"
pub fn encodeUndoKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'd', chain, height);
}

/// Key for the set hash after a committed height, prefix `s`.
/// The value is the 32-byte hash recorded in that commit, not a recomputation.
/// test "disconnect restores the recorded set hash"
pub fn encodeSetHashKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 's', chain, height);
}

/// Key for the chain tip marker, prefix `t` and the chain name.
/// No height in the key. The value is encodeTipValue.
/// test "codec v2 golden vectors"
pub fn encodeTipKey(allocator: std.mem.Allocator, chain: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, 't');
    try appendVarBytes(allocator, &bytes, chain);
    return bytes.toOwnedSlice(allocator);
}

/// Key for a block-index row, prefix `b` and a height.
/// The value is the display hash, not the raw block.
/// test "codec v2 golden vectors"
pub fn encodeBlockIndexKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'b', chain, height);
}

/// Key for a stored header, prefix `h` and a height.
/// The value is the 80-byte header.
/// test "codec v2 golden vectors"
pub fn encodeHeaderKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'h', chain, height);
}

/// Key for raw block bytes, prefix `r` and a height.
/// The value is the block, not a UTXO.
/// test "record block survives restart before connect"
pub fn encodeRawBlockKey(allocator: std.mem.Allocator, chain: []const u8, height: u32) ![]u8 {
    return keyWithHeight(allocator, 'r', chain, height);
}

/// Key for one named chainstate field, prefix `m` and the name.
/// No chain id. Callers use the same name at read and write.
/// test "codec v2 golden vectors"
pub fn encodeMetadataKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, 'm');
    try appendVarBytes(allocator, &bytes, name);
    return bytes.toOwnedSlice(allocator);
}

/// Lowercase hex of a byte slice, two chars per byte.
/// Golden vectors compare this form. It is not a key or a value layout.
/// test "codec v2 golden vectors"
pub fn toHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

/// Decode even-length hex into owned bytes.
/// Odd length or a bad nibble is InvalidHex. Upper and lower case both read.
/// test "codec v2 golden vectors"
pub fn fromHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    var out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        out[i] = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return out;
}

/// Compare live key and value encodings to CodecVectors.
/// A drift returns CodecVectorMismatch. The command that runs this is codec-vectors.
/// codec-vectors
pub fn verifyCodecVectors(allocator: std.mem.Allocator) !void {
    var txid: [32]u8 = undefined;
    for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
    const script_bytes = try fromHexAlloc(allocator, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    defer allocator.free(script_bytes);

    const key = try encodeUtxoKey(allocator, "testnet4", .{ .txid = txid, .vout = 1 });
    defer allocator.free(key);
    const key_hex = try toHexAlloc(allocator, key);
    defer allocator.free(key_hex);
    if (!std.mem.eql(u8, key_hex, CodecVectors.utxo_key_hex)) return error.CodecVectorMismatch;

    const value = try encodeUtxoValue(allocator, .{
        .height = 1,
        .vout = 1,
        .value_sats = 5_000_000_000,
        .coinbase = true,
        .script_pubkey = script_bytes,
    });
    defer allocator.free(value);
    const value_hex = try toHexAlloc(allocator, value);
    defer allocator.free(value_hex);
    if (!std.mem.eql(u8, value_hex, CodecVectors.utxo_value_hex)) return error.CodecVectorMismatch;

    const undo_key = try encodeUndoKey(allocator, "testnet4", 2);
    defer allocator.free(undo_key);
    const undo_hex = try toHexAlloc(allocator, undo_key);
    defer allocator.free(undo_hex);
    if (!std.mem.eql(u8, undo_hex, CodecVectors.undo_key_hex)) return error.CodecVectorMismatch;

    const tip_key = try encodeTipKey(allocator, "testnet4");
    defer allocator.free(tip_key);
    const tip_hex = try toHexAlloc(allocator, tip_key);
    defer allocator.free(tip_hex);
    if (!std.mem.eql(u8, tip_hex, CodecVectors.tip_key_hex)) return error.CodecVectorMismatch;

    const block_index_key = try encodeBlockIndexKey(allocator, "testnet4", 2);
    defer allocator.free(block_index_key);
    const block_index_hex = try toHexAlloc(allocator, block_index_key);
    defer allocator.free(block_index_hex);
    if (!std.mem.eql(u8, block_index_hex, CodecVectors.block_index_key_hex)) return error.CodecVectorMismatch;

    const header_key = try encodeHeaderKey(allocator, "testnet4", 2);
    defer allocator.free(header_key);
    const header_hex = try toHexAlloc(allocator, header_key);
    defer allocator.free(header_hex);
    if (!std.mem.eql(u8, header_hex, CodecVectors.header_key_hex)) return error.CodecVectorMismatch;

    const metadata_key = try encodeMetadataKey(allocator, "codec_version");
    defer allocator.free(metadata_key);
    const metadata_hex = try toHexAlloc(allocator, metadata_key);
    defer allocator.free(metadata_hex);
    if (!std.mem.eql(u8, metadata_hex, CodecVectors.metadata_key_hex)) return error.CodecVectorMismatch;
}

/// Big-endian height, then the internal block hash.
/// Stored under the tip key. This is not a UTXO value.
/// test "commit block writes created utxos undo tip metadata and counters"
pub fn encodeTipValue(allocator: std.mem.Allocator, height: u32, block_hash: [32]u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, height);
    try bytes.appendSlice(allocator, block_hash[0..]);
    return bytes.toOwnedSlice(allocator);
}

/// Undo records a commit must be able to reverse: outpoint, height, value, coinbase, script.
/// One record per external spend, in that spend's order.
/// test "commit block writes created utxos undo tip metadata and counters"
pub fn encodeUndoValue(allocator: std.mem.Allocator, entries: []const UndoEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try appendU32Be(allocator, &bytes, @intCast(entries.len));
    for (entries) |entry| {
        try bytes.appendSlice(allocator, entry.outpoint.txid[0..]);
        try appendU32Be(allocator, &bytes, entry.outpoint.vout);
        try appendU32Be(allocator, &bytes, entry.utxo.height);
        try appendU64Be(allocator, &bytes, entry.utxo.value_sats);
        try bytes.append(allocator, if (entry.utxo.coinbase) 1 else 0);
        try appendVarBytes32(allocator, &bytes, entry.utxo.script_pubkey);
    }
    return bytes.toOwnedSlice(allocator);
}

/// Inverse of encodeUndoValue. Each script is owned by the caller.
/// A short payload is UndoTruncated. Disconnect reads this before it mutates.
/// test "disconnect restores the recorded set hash"
pub fn decodeUndoValue(allocator: std.mem.Allocator, bytes: []const u8) ![]UndoEntry {
    if (bytes.len < 4) return error.UndoTruncated;
    const count = std.mem.readInt(u32, bytes[0..4], .big);
    // One entry is at least the fixed fields. A flipped count must not allocate.
    if (count > (bytes.len - 4) / 53) return error.UndoTruncated;
    var entries = try allocator.alloc(UndoEntry, count);
    errdefer allocator.free(entries);
    var offset: usize = 4;
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |entry| allocator.free(entry.utxo.script_pubkey);
    }
    while (filled < count) : (filled += 1) {
        if (offset + 32 + 4 + 4 + 8 + 1 + 4 > bytes.len) return error.UndoTruncated;
        var txid: [32]u8 = undefined;
        @memcpy(&txid, bytes[offset..][0..32]);
        offset += 32;
        const vout = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const height = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const value_sats = std.mem.readInt(u64, bytes[offset..][0..8], .big);
        offset += 8;
        const coinbase = bytes[offset] == 1;
        offset += 1;
        const script_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        if (offset + script_len > bytes.len) return error.UndoTruncated;
        const script = try allocator.dupe(u8, bytes[offset..][0..script_len]);
        offset += script_len;
        entries[filled] = .{
            .outpoint = .{ .txid = txid, .vout = vout },
            .utxo = .{
                .height = height,
                .vout = vout,
                .value_sats = value_sats,
                .coinbase = coinbase,
                .script_pubkey = script,
            },
        };
    }
    if (offset != bytes.len) return error.UndoTruncated;
    return entries;
}

/// Free scripts from decodeUndoValue.
/// test "disconnect restores the recorded set hash"
pub fn freeUndoEntries(allocator: std.mem.Allocator, entries: []UndoEntry) void {
    for (entries) |entry| allocator.free(entry.utxo.script_pubkey);
    allocator.free(entries);
}

/// Read a UTXO value back: height, satoshis, coinbase, script.
/// The outpoint supplies vout. A short or truncated script is an error.
/// test "direct utxo multi get preserves order missing slots and decoded equality"
pub fn decodeUtxoValue(allocator: std.mem.Allocator, outpoint: Outpoint, value: []const u8) !StoredUtxo {
    if (value.len < 17) return error.UtxoValueTooShort;
    const height = std.mem.readInt(u32, value[0..4], .big);
    const value_sats = std.mem.readInt(u64, value[4..12], .big);
    const coinbase = value[12] == 1;
    const script_len = std.mem.readInt(u32, value[13..17], .big);
    if (17 + script_len > value.len) return error.UtxoValueTruncatedScript;
    return .{
        .height = height,
        .vout = outpoint.vout,
        .value_sats = value_sats,
        .coinbase = coinbase,
        .script_pubkey = try allocator.dupe(u8, value[17 .. 17 + script_len]),
    };
}

fn keyWithHeight(allocator: std.mem.Allocator, prefix: u8, chain: []const u8, height: u32) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.append(allocator, prefix);
    try appendVarBytes(allocator, &bytes, chain);
    try appendU32Be(allocator, &bytes, height);
    return bytes.toOwnedSlice(allocator);
}

fn appendVarBytes(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > 252) return error.ValueTooLarge;
    try bytes.append(allocator, @intCast(value.len));
    try bytes.appendSlice(allocator, value);
}

fn appendVarBytes32(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try appendU32Be(allocator, bytes, @intCast(value.len));
    try bytes.appendSlice(allocator, value);
}

fn appendU32Be(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u32) !void {
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendU64Be(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u64) !void {
    try bytes.append(allocator, @intCast((value >> 56) & 0xff));
    try bytes.append(allocator, @intCast((value >> 48) & 0xff));
    try bytes.append(allocator, @intCast((value >> 40) & 0xff));
    try bytes.append(allocator, @intCast((value >> 32) & 0xff));
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendU64Le(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), value: u64) !void {
    try bytes.append(allocator, @intCast(value & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 32) & 0xff));
    try bytes.append(allocator, @intCast((value >> 40) & 0xff));
    try bytes.append(allocator, @intCast((value >> 48) & 0xff));
    try bytes.append(allocator, @intCast((value >> 56) & 0xff));
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}
test "codec v2 golden vectors" {
    try verifyCodecVectors(std.testing.allocator);
}

test "scratch utxo key encoding matches codec vector" {
    const allocator = std.testing.allocator;
    var txid: [32]u8 = undefined;
    for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try encodeUtxoKeyInto(allocator, &bytes, "testnet4", .{ .txid = txid, .vout = 1 });
    const hex = try toHexAlloc(allocator, bytes.items);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings(CodecVectors.utxo_key_hex, hex);
}
