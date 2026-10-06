//! Adapter from the node to the Zig secp256k1 kernel. Sighash and TapTweak hashing stay here in the node.
//! Verification is public-data and variable-time by design.
//! The kernel campaign measured 1.93 times libsecp at the same operation count, 1950 field
//! multiplications. The residual is scheduling inside and around the multiply, not a missing algorithm.
//! The 5x52 field reached ECDSA ratio_min 1.844, below the keep bar, not worse. `lineage.created`
//! is clean_room. `lineage.optimized` stays null. No reference-informed code was kept
//! (`zig_own_curve_kernel_campaign_host_2026-10-04.json`).
//! The secp module is ReleaseFast, and each crypto function turns runtime safety off, because an
//! imported ReleaseFast module was still emitting overflow checks. `point_double` went from
//! `sub sp, #0xe0` with two panic calls to `sub sp, #0xc0` with no `bl`. Inlining the field ops
//! left that frame and cut stores from 9 to 8 and loads from 7 to 6.
//! Does not select which binary links libsecp. The bench target does; the node does not.

const std = @import("std");
const options = @import("crypto_options");
const secp = @import("secp256k1");
/// X-only output key and parity from a BIP341 tweak.
/// A false return is a failed signature, not a caught consensus error.
/// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
pub const TweakResult = @import("crypto_types.zig").TweakResult;
/// own_curve verifier. Present only when that lane is compiled.
/// A false return is a failed signature, not a caught consensus error.
/// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
pub const OwnVerifier = struct {
    /// Construct the verifier or runner this binary is allowed to use.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn create() OwnVerifier {
        return .{};
    }
    /// Drop a verifier or runner the matching create allocated.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn destroy(_: *OwnVerifier) void {}
    /// ECDSA verify of a DER signature over a 32-byte sighash. Public data, variable-time.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifyEcdsaDer(_: *OwnVerifier, key: []const u8, sig: []const u8, msg: *const [32]u8) bool {
        const ok = secp.verifyEcdsa(key, msg, sig) catch false;
        if (probe("ecdsa", key, msg, sig, if (ok) "true" else "false")) return false;
        return ok;
    }
    /// BIP340 verify. Public data, variable-time, same as ECDSA.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifySchnorr(_: *OwnVerifier, key: []const u8, sig: []const u8, msg: []const u8) bool {
        const ok = secp.verifySchnorr(key, msg, sig) catch false;
        if (probe("schnorr", key, msg, sig, if (ok) "true" else "false")) return false;
        return ok;
    }
    /// BIP341 key tweak. Returns null when the tweak is not on the curve.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakPubkeyXOnly(_: *OwnVerifier, key: []const u8, tweak: *const [32]u8) ?TweakResult {
        const result = secp.addXOnlyTweak(key, tweak) catch return null;
        if (options.probe) {
            const text = std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ std.fmt.bytesToHex(result.output_xonly, .lower), result.parity }) catch @panic("probe allocation");
            defer std.heap.page_allocator.free(text);
            if (probe("tweak", key, tweak, &.{}, text)) return null;
        }
        return .{ .output_xonly = result.output_xonly, .parity = result.parity };
    }
    /// BIP341 tweak check: parity and x-only key both match.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakAddCheck(self: *OwnVerifier, out: []const u8, parity: u8, key: []const u8, tweak: *const [32]u8) bool {
        const result = self.taprootTweakPubkeyXOnly(key, tweak) orelse return false;
        return parity == result.parity and std.mem.eql(u8, out, &result.output_xonly);
    }
};
// Unselected backends cannot be constructed in a candidate-only binary.
/// Unselected own_curve or libsecp backend. Construction fails closed.
/// A false return is a failed signature, not a caught consensus error.
/// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
pub const DisabledVerifier = struct {
    /// Construct the verifier or runner this binary is allowed to use.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn create() !DisabledVerifier {
        return error.CryptoBackendNotCompiled;
    }
    /// Drop a verifier or runner the matching create allocated.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn destroy(_: *DisabledVerifier) void {}
    /// ECDSA verify of a DER signature over a 32-byte sighash. Public data, variable-time.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifyEcdsaDer(_: *DisabledVerifier, _: []const u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
    /// BIP340 verify. Public data, variable-time, same as ECDSA.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifySchnorr(_: *DisabledVerifier, _: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    /// BIP341 key tweak. Returns null when the tweak is not on the curve.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakPubkeyXOnly(_: *DisabledVerifier, _: []const u8, _: *const [32]u8) ?TweakResult {
        return null;
    }
    /// BIP341 tweak check: parity and x-only key both match.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakAddCheck(_: *DisabledVerifier, _: []const u8, _: u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
};
/// Unselected pure backend. Construction fails so a candidate binary cannot call it.
/// A false return is a failed signature, not a caught consensus error.
/// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
pub const DisabledPure = struct {
    /// Construct the verifier or runner this binary is allowed to use.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn create() DisabledPure {
        @panic("ecosystem backend not compiled");
    }
    /// Drop a verifier or runner the matching create allocated.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn destroy(_: *DisabledPure) void {}
    /// ECDSA verify of a DER signature over a 32-byte sighash. Public data, variable-time.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifyEcdsaDer(_: *DisabledPure, _: []const u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
    /// BIP340 verify. Public data, variable-time, same as ECDSA.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn verifySchnorr(_: *DisabledPure, _: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    /// BIP341 key tweak. Returns null when the tweak is not on the curve.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakPubkeyXOnly(_: *DisabledPure, _: []const u8, _: *const [32]u8) ?TweakResult {
        return null;
    }
    /// BIP341 tweak check: parity and x-only key both match.
    /// A false return is a failed signature, not a caught consensus error.
    /// test "verifier dispatch records ecdsa schnorr and taproot tweak separately"
    pub fn taprootTweakAddCheck(_: *DisabledPure, _: []const u8, _: u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
};

fn probe(op: []const u8, key: []const u8, msg: []const u8, sig: []const u8, result: []const u8) bool {
    if (!options.probe) return false;
    const a = hex(key);
    defer std.heap.page_allocator.free(a);
    const b = hex(msg);
    defer std.heap.page_allocator.free(b);
    const c = hex(sig);
    defer std.heap.page_allocator.free(c);
    std.debug.print("rb.crypto_call {s} {s} {s} {s} {s}\n", .{ op, a, b, c, result });
    return std.mem.eql(u8, options.reject, op);
}
fn hex(bytes: []const u8) []u8 {
    const out = std.heap.page_allocator.alloc(u8, bytes.len * 2) catch @panic("probe allocation");
    const digits = "0123456789abcdef";
    for (bytes, 0..) |v, i| {
        out[i * 2] = digits[v >> 4];
        out[i * 2 + 1] = digits[v & 15];
    }
    return out;
}
