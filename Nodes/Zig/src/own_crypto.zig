//! Thin node adapter; Bitcoin sighashes and TapTweak hashing stay in the node.
const std = @import("std");
const options = @import("crypto_options");
const secp = @import("secp256k1");
pub const TweakResult = @import("crypto_types.zig").TweakResult;
pub const OwnVerifier = struct {
    pub fn create() OwnVerifier {
        return .{};
    }
    pub fn destroy(_: *OwnVerifier) void {}
    pub fn verifyEcdsaDer(_: *OwnVerifier, key: []const u8, sig: []const u8, msg: *const [32]u8) bool {
        const ok = secp.verifyEcdsa(key, msg, sig) catch false;
        if (probe("ecdsa", key, msg, sig, if (ok) "true" else "false")) return false;
        return ok;
    }
    pub fn verifySchnorr(_: *OwnVerifier, key: []const u8, sig: []const u8, msg: []const u8) bool {
        const ok = secp.verifySchnorr(key, msg, sig) catch false;
        if (probe("schnorr", key, msg, sig, if (ok) "true" else "false")) return false;
        return ok;
    }
    pub fn taprootTweakPubkeyXOnly(_: *OwnVerifier, key: []const u8, tweak: *const [32]u8) ?TweakResult {
        const result = secp.addXOnlyTweak(key, tweak) catch return null;
        if (options.probe) {
            const text = std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ std.fmt.bytesToHex(result.output_xonly, .lower), result.parity }) catch @panic("probe allocation");
            defer std.heap.page_allocator.free(text);
            if (probe("tweak", key, tweak, &.{}, text)) return null;
        }
        return .{ .output_xonly = result.output_xonly, .parity = result.parity };
    }
    pub fn taprootTweakAddCheck(self: *OwnVerifier, out: []const u8, parity: u8, key: []const u8, tweak: *const [32]u8) bool {
        const result = self.taprootTweakPubkeyXOnly(key, tweak) orelse return false;
        return parity == result.parity and std.mem.eql(u8, out, &result.output_xonly);
    }
};
// Unselected backends cannot be constructed in a candidate-only binary.
pub const DisabledVerifier = struct {
    pub fn create() !DisabledVerifier {
        return error.CryptoBackendNotCompiled;
    }
    pub fn destroy(_: *DisabledVerifier) void {}
    pub fn verifyEcdsaDer(_: *DisabledVerifier, _: []const u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
    pub fn verifySchnorr(_: *DisabledVerifier, _: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn taprootTweakPubkeyXOnly(_: *DisabledVerifier, _: []const u8, _: *const [32]u8) ?TweakResult {
        return null;
    }
    pub fn taprootTweakAddCheck(_: *DisabledVerifier, _: []const u8, _: u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
};
pub const DisabledPure = struct {
    pub fn create() DisabledPure {
        @panic("ecosystem backend not compiled");
    }
    pub fn destroy(_: *DisabledPure) void {}
    pub fn verifyEcdsaDer(_: *DisabledPure, _: []const u8, _: []const u8, _: *const [32]u8) bool {
        return false;
    }
    pub fn verifySchnorr(_: *DisabledPure, _: []const u8, _: []const u8, _: []const u8) bool {
        return false;
    }
    pub fn taprootTweakPubkeyXOnly(_: *DisabledPure, _: []const u8, _: *const [32]u8) ?TweakResult {
        return null;
    }
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
