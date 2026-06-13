const std = @import("std");

const Secp256k1 = std.crypto.ecc.Secp256k1;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

pub const TweakResult = struct {
    output_xonly: [32]u8,
    parity: u8,
};

pub const PureVerifier = struct {
    pub fn create() PureVerifier {
        return .{};
    }

    pub fn destroy(_: *PureVerifier) void {}

    pub fn verifyEcdsaDer(_: *PureVerifier, pubkey_bytes: []const u8, der_sig: []const u8, msg32: *const [32]u8) bool {
        const public_key = Ecdsa.PublicKey.fromSec1(pubkey_bytes) catch return false;
        const sig = Ecdsa.Signature.fromDer(der_sig) catch return false;
        sig.verifyPrehashed(msg32.*, public_key) catch return false;
        return true;
    }

    pub fn verifySchnorr(_: *PureVerifier, xonly_pubkey_bytes: []const u8, sig64: []const u8, msg: []const u8) bool {
        if (xonly_pubkey_bytes.len != 32 or sig64.len != 64) return false;
        const point = liftX(xonly_pubkey_bytes) catch return false;
        const r_x = parseField(sig64[0..32]) catch return false;
        const s = Secp256k1.scalar.Scalar.fromBytes(sig64[32..64].*, .big) catch return false;
        if (s.isZero()) return false;
        const e = schnorrChallenge(sig64[0..32], xonly_pubkey_bytes, msg);
        const s_g = Secp256k1.basePoint.mulPublic(s.toBytes(.big), .big) catch return false;
        const e_p = point.mulPublic(e.toBytes(.big), .big) catch return false;
        const r = s_g.sub(e_p);
        r.rejectIdentity() catch return false;
        const affine = r.affineCoordinates();
        return !affine.y.isOdd() and affine.x.equivalent(r_x);
    }

    pub fn taprootTweakAddCheck(
        self: *PureVerifier,
        tweaked_xonly: []const u8,
        parity: u8,
        internal_xonly: []const u8,
        tweak32: *const [32]u8,
    ) bool {
        const result = self.taprootTweakPubkeyXOnly(internal_xonly, tweak32) orelse return false;
        return parity == result.parity and std.mem.eql(u8, tweaked_xonly, result.output_xonly[0..]);
    }

    pub fn taprootTweakPubkeyXOnly(_: *PureVerifier, internal_xonly: []const u8, tweak32: *const [32]u8) ?TweakResult {
        const internal = liftX(internal_xonly) catch return null;
        const tweak = Secp256k1.scalar.Scalar.fromBytes(tweak32.*, .big) catch return null;
        const output = if (tweak.isZero()) internal else blk: {
            const tweak_point = Secp256k1.basePoint.mulPublic(tweak.toBytes(.big), .big) catch return null;
            break :blk internal.add(tweak_point);
        };
        output.rejectIdentity() catch return null;
        const affine = output.affineCoordinates();
        return .{ .output_xonly = affine.x.toBytes(.big), .parity = @intFromBool(affine.y.isOdd()) };
    }
};

fn parseField(bytes: []const u8) !Secp256k1.Fe {
    if (bytes.len != 32) return error.InvalidEncoding;
    return Secp256k1.Fe.fromBytes(bytes[0..32].*, .big);
}

fn liftX(xonly: []const u8) !Secp256k1 {
    const x = try parseField(xonly);
    const y = try Secp256k1.recoverY(x, false);
    return Secp256k1.fromAffineCoordinates(.{ .x = x, .y = y });
}

fn schnorrChallenge(r_x: []const u8, pubkey_x: []const u8, msg: []const u8) Secp256k1.scalar.Scalar {
    const tag_hash = sha256("BIP0340/challenge");
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(tag_hash[0..]);
    hasher.update(tag_hash[0..]);
    hasher.update(r_x[0..32]);
    hasher.update(pubkey_x[0..32]);
    hasher.update(msg);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const reduced: [64]u8 = [_]u8{0} ** 32 ++ digest;
    return Secp256k1.scalar.Scalar.fromBytes64(reduced, .big);
}

fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

test "pure secp rejects malformed encodings" {
    var verifier = PureVerifier.create();
    defer verifier.destroy();
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!verifier.verifySchnorr(&.{}, &.{}, &.{}));
    try std.testing.expect(verifier.taprootTweakPubkeyXOnly(&.{}, &zero) == null);
}
