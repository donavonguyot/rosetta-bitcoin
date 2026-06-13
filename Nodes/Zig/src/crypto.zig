const std = @import("std");
const pure_secp = @import("pure_secp.zig");
pub const PureVerifier = pure_secp.PureVerifier;
pub const TweakResult = pure_secp.TweakResult;

const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
});

pub const NativeVerifier = struct {
    ctx: *c.secp256k1_context,

    pub fn create() !NativeVerifier {
        const ctx = c.secp256k1_context_create(c.SECP256K1_CONTEXT_VERIFY);
        if (ctx == null) return error.NativeCryptoUnavailable;
        return .{ .ctx = ctx.? };
    }

    pub fn destroy(self: *NativeVerifier) void {
        c.secp256k1_context_destroy(self.ctx);
    }

    pub fn verifyEcdsaDer(self: *NativeVerifier, pubkey_bytes: []const u8, der_sig: []const u8, msg32: *const [32]u8) bool {
        var pubkey: c.secp256k1_pubkey = undefined;
        if (c.secp256k1_ec_pubkey_parse(self.ctx, &pubkey, pubkey_bytes.ptr, pubkey_bytes.len) != 1) return false;
        var sig: c.secp256k1_ecdsa_signature = undefined;
        if (c.secp256k1_ecdsa_signature_parse_der(self.ctx, &sig, der_sig.ptr, der_sig.len) != 1) return false;
        _ = c.secp256k1_ecdsa_signature_normalize(self.ctx, &sig, &sig);
        return c.secp256k1_ecdsa_verify(self.ctx, &sig, msg32, &pubkey) == 1;
    }

    pub fn verifySchnorr(self: *NativeVerifier, xonly_pubkey_bytes: []const u8, sig64: []const u8, msg: []const u8) bool {
        if (xonly_pubkey_bytes.len != 32 or sig64.len != 64) return false;
        var pubkey: c.secp256k1_xonly_pubkey = undefined;
        if (c.secp256k1_xonly_pubkey_parse(self.ctx, &pubkey, xonly_pubkey_bytes.ptr) != 1) return false;
        return c.secp256k1_schnorrsig_verify(self.ctx, sig64.ptr, msg.ptr, msg.len, &pubkey) == 1;
    }

    pub fn taprootTweakAddCheck(
        self: *NativeVerifier,
        tweaked_xonly: []const u8,
        parity: u8,
        internal_xonly: []const u8,
        tweak32: *const [32]u8,
    ) bool {
        if (tweaked_xonly.len != 32 or internal_xonly.len != 32) return false;
        var internal: c.secp256k1_xonly_pubkey = undefined;
        if (c.secp256k1_xonly_pubkey_parse(self.ctx, &internal, internal_xonly.ptr) != 1) return false;
        return c.secp256k1_xonly_pubkey_tweak_add_check(
            self.ctx,
            tweaked_xonly.ptr,
            @intCast(parity),
            &internal,
            tweak32,
        ) == 1;
    }

    pub fn taprootTweakPubkeyXOnly(
        self: *NativeVerifier,
        internal_xonly: []const u8,
        tweak32: *const [32]u8,
    ) ?TweakResult {
        if (internal_xonly.len != 32) return null;
        var internal: c.secp256k1_xonly_pubkey = undefined;
        if (c.secp256k1_xonly_pubkey_parse(self.ctx, &internal, internal_xonly.ptr) != 1) return null;
        var output_pubkey: c.secp256k1_pubkey = undefined;
        if (c.secp256k1_xonly_pubkey_tweak_add(self.ctx, &output_pubkey, &internal, tweak32) != 1) return null;
        var output_xonly_pubkey: c.secp256k1_xonly_pubkey = undefined;
        var parity_c: c_int = 0;
        if (c.secp256k1_xonly_pubkey_from_pubkey(self.ctx, &output_xonly_pubkey, &parity_c, &output_pubkey) != 1) return null;
        var output_xonly: [32]u8 = undefined;
        if (c.secp256k1_xonly_pubkey_serialize(self.ctx, &output_xonly, &output_xonly_pubkey) != 1) return null;
        return .{ .output_xonly = output_xonly, .parity = @intCast(parity_c) };
    }
};

pub const CryptoVerifier = union(enum) {
    native: *NativeVerifier,
    pure: *PureVerifier,

    pub fn verifyEcdsaDer(self: CryptoVerifier, pubkey_bytes: []const u8, der_sig: []const u8, msg32: *const [32]u8) bool {
        return switch (self) {
            .native => |verifier| verifier.verifyEcdsaDer(pubkey_bytes, der_sig, msg32),
            .pure => |verifier| verifier.verifyEcdsaDer(pubkey_bytes, der_sig, msg32),
        };
    }

    pub fn verifySchnorr(self: CryptoVerifier, xonly_pubkey_bytes: []const u8, sig64: []const u8, msg: []const u8) bool {
        return switch (self) {
            .native => |verifier| verifier.verifySchnorr(xonly_pubkey_bytes, sig64, msg),
            .pure => |verifier| verifier.verifySchnorr(xonly_pubkey_bytes, sig64, msg),
        };
    }

    pub fn taprootTweakAddCheck(
        self: CryptoVerifier,
        tweaked_xonly: []const u8,
        parity: u8,
        internal_xonly: []const u8,
        tweak32: *const [32]u8,
    ) bool {
        return switch (self) {
            .native => |verifier| verifier.taprootTweakAddCheck(tweaked_xonly, parity, internal_xonly, tweak32),
            .pure => |verifier| verifier.taprootTweakAddCheck(tweaked_xonly, parity, internal_xonly, tweak32),
        };
    }

    pub fn taprootTweakPubkeyXOnly(
        self: CryptoVerifier,
        internal_xonly: []const u8,
        tweak32: *const [32]u8,
    ) ?TweakResult {
        return switch (self) {
            .native => |verifier| verifier.taprootTweakPubkeyXOnly(internal_xonly, tweak32),
            .pure => |verifier| verifier.taprootTweakPubkeyXOnly(internal_xonly, tweak32),
        };
    }
};

pub fn available() bool {
    var verifier = NativeVerifier.create() catch return false;
    verifier.destroy();
    return true;
}

test "pure schnorr verifier accepts BIP340 variable-length messages" {
    const allocator = std.testing.allocator;
    var verifier = PureVerifier.create();
    defer verifier.destroy();
    const pubkey = try fromHexAlloc(allocator, "778CAA53B4393AC467774D09497A87224BF9FAB6F6E68B23086497324D6FD117");
    defer allocator.free(pubkey);
    const msg = try fromHexAlloc(allocator, "99999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999");
    defer allocator.free(msg);
    const sig = try fromHexAlloc(allocator, "403B12B0D8555A344175EA7EC746566303321E5DBFA8BE6F091635163ECA79A8585ED3E3170807E7C03B720FC54C7B23897FCBA0E9D0B4A06894CFD249F22367");
    defer allocator.free(sig);
    try std.testing.expect(verifier.verifySchnorr(pubkey, sig, msg));
}

pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn doubleSha256(data: []const u8) [32]u8 {
    const first = sha256(data);
    return sha256(first[0..]);
}

pub fn sha1(data: []const u8) [20]u8 {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &out, .{});
    return out;
}

pub fn ripemd160(data: []const u8) [20]u8 {
    var state = [_]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
    var offset: usize = 0;
    while (offset + 64 <= data.len) : (offset += 64) {
        ripemdTransform(&state, data[offset .. offset + 64]);
    }

    var final = [_]u8{0} ** 128;
    const remaining = data.len - offset;
    @memcpy(final[0..remaining], data[offset..]);
    final[remaining] = 0x80;
    const final_len: usize = if (remaining < 56) 64 else 128;
    std.mem.writeInt(u64, final[final_len - 8 .. final_len][0..8], @as(u64, data.len) * 8, .little);
    var pos: usize = 0;
    while (pos < final_len) : (pos += 64) {
        ripemdTransform(&state, final[pos .. pos + 64]);
    }

    var out: [20]u8 = undefined;
    for (state, 0..) |word, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], word, .little);
    return out;
}

pub fn hash160(data: []const u8) [20]u8 {
    const sha = sha256(data);
    return ripemd160(sha[0..]);
}

pub fn taggedHash(tag: []const u8, data: []const u8) [32]u8 {
    const tag_hash = sha256(tag);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(tag_hash[0..]);
    hasher.update(tag_hash[0..]);
    hasher.update(data);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn displayHashAlloc(allocator: std.mem.Allocator, internal_hash: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, internal_hash.len * 2);
    for (internal_hash, 0..) |_, i| {
        const byte = internal_hash[internal_hash.len - 1 - i];
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub fn internalHashFromDisplay(allocator: std.mem.Allocator, display: []const u8) ![32]u8 {
    if (display.len != 64) return error.InvalidHashHex;
    const raw = try fromHexAlloc(allocator, display);
    defer allocator.free(raw);
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = raw[31 - i];
    return out;
}

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

pub fn toHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}

const ripemd_r1 = [_]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    7,  4,  13, 1,  10, 6,  15, 3,  12, 0,  9,  5,  2,  14, 11, 8,
    3,  10, 14, 4,  9,  15, 8,  1,  2,  7,  0,  6,  13, 11, 5,  12,
    1,  9,  11, 10, 0,  8,  12, 4,  13, 3,  7,  15, 14, 5,  6,  2,
    4,  0,  5,  9,  7,  12, 2,  10, 14, 1,  3,  8,  11, 6,  15, 13,
};

const ripemd_r2 = [_]u8{
    5,  14, 7,  0,  9,  2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
    6,  11, 3,  7,  0,  13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
    15, 5,  1,  3,  7,  14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
    8,  6,  4,  1,  3,  11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
    12, 15, 10, 4,  1,  5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
};

const ripemd_s1 = [_]u8{
    11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
    7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
    11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
    11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
    9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
};

const ripemd_s2 = [_]u8{
    8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
    9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
    9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
    15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
    8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
};

fn ripemdTransform(state: *[5]u32, chunk: []const u8) void {
    var words: [16]u32 = undefined;
    for (&words, 0..) |*word, i| word.* = std.mem.readInt(u32, chunk[i * 4 ..][0..4], .little);

    var a1 = state[0];
    var b1 = state[1];
    var c1 = state[2];
    var d1 = state[3];
    var e1 = state[4];
    var a2 = a1;
    var b2 = b1;
    var c2 = c1;
    var d2 = d1;
    var e2 = e1;

    for (0..80) |j| {
        const round: u32 = @intCast(j / 16);
        const t1 = std.math.rotl(u32, a1 +% ripemdF(round, b1, c1, d1) +% words[ripemd_r1[j]] +% ripemdK1(round), ripemd_s1[j]) +% e1;
        a1 = e1;
        e1 = d1;
        d1 = std.math.rotl(u32, c1, 10);
        c1 = b1;
        b1 = t1;

        const round2: u32 = @intCast(j / 16);
        const t2 = std.math.rotl(u32, a2 +% ripemdF(4 - round2, b2, c2, d2) +% words[ripemd_r2[j]] +% ripemdK2(round2), ripemd_s2[j]) +% e2;
        a2 = e2;
        e2 = d2;
        d2 = std.math.rotl(u32, c2, 10);
        c2 = b2;
        b2 = t2;
    }

    const tmp = state[1] +% c1 +% d2;
    state[1] = state[2] +% d1 +% e2;
    state[2] = state[3] +% e1 +% a2;
    state[3] = state[4] +% a1 +% b2;
    state[4] = state[0] +% b1 +% c2;
    state[0] = tmp;
}

fn ripemdF(round: u32, x: u32, y: u32, z: u32) u32 {
    return switch (round) {
        0 => x ^ y ^ z,
        1 => (x & y) | (~x & z),
        2 => (x | ~y) ^ z,
        3 => (x & z) | (y & ~z),
        else => x ^ (y | ~z),
    };
}

fn ripemdK1(round: u32) u32 {
    return switch (round) {
        0 => 0x00000000,
        1 => 0x5a827999,
        2 => 0x6ed9eba1,
        3 => 0x8f1bbcdc,
        else => 0xa953fd4e,
    };
}

fn ripemdK2(round: u32) u32 {
    return switch (round) {
        0 => 0x50a28be6,
        1 => 0x5c4dd124,
        2 => 0x6d703ef3,
        3 => 0x7a6d76e9,
        else => 0x00000000,
    };
}

test "native secp256k1 extrakeys and schnorr backend is available" {
    try std.testing.expect(available());
}

test "display hash reverses internal bytes" {
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i);
    const display = try displayHashAlloc(std.testing.allocator, bytes[0..]);
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings("1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100", display);
}

test "ripemd160 known vectors" {
    const empty = ripemd160("");
    const empty_hex = try toHexAlloc(std.testing.allocator, empty[0..]);
    defer std.testing.allocator.free(empty_hex);
    try std.testing.expectEqualStrings("9c1185a5c5e9fc54612808977ee8f548b2258d31", empty_hex);

    const abc = ripemd160("abc");
    const abc_hex = try toHexAlloc(std.testing.allocator, abc[0..]);
    defer std.testing.allocator.free(abc_hex);
    try std.testing.expectEqualStrings("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc", abc_hex);
}
