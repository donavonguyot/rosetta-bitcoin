//! Test-only public C API benchmark adapter; no curve implementation lives here.
const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
});
const E = error{Invalid};
pub fn parsePublicKey(key: []const u8) E!c.secp256k1_pubkey {
    var out: c.secp256k1_pubkey = undefined;
    if (c.secp256k1_ec_pubkey_parse(c.secp256k1_context_static, &out, key.ptr, key.len) != 1) return error.Invalid;
    return out;
}
pub fn verifyEcdsa(key: []const u8, msg: []const u8, sig: []const u8) E!bool {
    if (msg.len != 32) return error.Invalid;
    const pk = try parsePublicKey(key);
    var parsed: c.secp256k1_ecdsa_signature = undefined;
    if (c.secp256k1_ecdsa_signature_parse_der(c.secp256k1_context_static, &parsed, sig.ptr, sig.len) != 1) return error.Invalid;
    _ = c.secp256k1_ecdsa_signature_normalize(c.secp256k1_context_static, &parsed, &parsed);
    return c.secp256k1_ecdsa_verify(c.secp256k1_context_static, &parsed, msg.ptr, &pk) == 1;
}
pub fn verifySchnorr(key: []const u8, msg: []const u8, sig: []const u8) E!bool {
    if (key.len != 32 or sig.len != 64) return error.Invalid;
    var pk: c.secp256k1_xonly_pubkey = undefined;
    if (c.secp256k1_xonly_pubkey_parse(c.secp256k1_context_static, &pk, key.ptr) != 1) return error.Invalid;
    return c.secp256k1_schnorrsig_verify(c.secp256k1_context_static, sig.ptr, msg.ptr, msg.len, &pk) == 1;
}
pub fn addXOnlyTweak(key: []const u8, tweak: []const u8) E!struct { x: [32]u8, parity: c_int } {
    if (key.len != 32 or tweak.len != 32) return error.Invalid;
    var pk: c.secp256k1_xonly_pubkey = undefined;
    var out: c.secp256k1_pubkey = undefined;
    if (c.secp256k1_xonly_pubkey_parse(c.secp256k1_context_static, &pk, key.ptr) != 1) return error.Invalid;
    if (c.secp256k1_xonly_pubkey_tweak_add(c.secp256k1_context_static, &out, &pk, tweak.ptr) != 1) return error.Invalid;
    var parity: c_int = undefined;
    var x: [32]u8 = undefined;
    if (c.secp256k1_xonly_pubkey_from_pubkey(c.secp256k1_context_static, &pk, &parity, &out) != 1) return error.Invalid;
    if (c.secp256k1_xonly_pubkey_serialize(c.secp256k1_context_static, &x, &pk) != 1) return error.Invalid;
    return .{ .x = x, .parity = parity };
}
