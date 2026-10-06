//! libsecp256k1 binding for ECDSA, BIP340 Schnorr, and the BIP341 tweak.
//! The node calls this only on the c_binding lane. Checks are variable-time on public data.
//! Does not link into an own_curve node binary.

const TweakResult = @import("crypto_types.zig").TweakResult;
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
