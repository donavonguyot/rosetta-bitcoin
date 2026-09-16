//! Radix 2^52 experiment derived by polynomial convolution and 2^256 = 2^32+977 (mod p).
const std = @import("std");
pub const p: u256 = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
const mask: u64 = (1 << 52) - 1;
const top: u64 = (1 << 48) - 1;
const complement: u64 = (1 << 32) + 977;

pub fn Kernel(comptime checked: bool) type {
    return struct {
        pub fn Field(comptime mag: u8) type {
            if (mag == 0 or mag > 8) @compileError("field magnitude must be 1..8");
            return struct {
                limbs: [5]u64,
                pub const magnitude = mag;
                const Self = @This();
                pub inline fn assertBounds(self: Self) void {
                    if (checked) {
                        inline for (0..4) |i| std.debug.assert(self.limbs[i] <= @as(u64, mag) * mask);
                        std.debug.assert(self.limbs[4] <= @as(u64, mag) * top);
                    }
                }
                pub inline fn fromInt(x: u256) Field(1) {
                    return .{ .limbs = .{ @truncate(x & mask), @truncate((x >> 52) & mask), @truncate((x >> 104) & mask), @truncate((x >> 156) & mask), @intCast(x >> 208) } };
                }
                pub inline fn integer(self: Self) u256 {
                    const v = self.weak();
                    var x: u256 = 0;
                    inline for (0..5) |i| x |= @as(u256, v.limbs[i]) << (52 * i);
                    return if (x >= p) x - p else x;
                }
                pub inline fn weak(self: Self) Field(1) {
                    @setRuntimeSafety(checked);
                    self.assertBounds();
                    var t: [5]u128 = undefined;
                    inline for (0..5) |i| t[i] = self.limbs[i];
                    return finish(t);
                }
                pub inline fn add(self: Self, b: anytype) Field(mag + @TypeOf(b).magnitude) {
                    @setRuntimeSafety(checked);
                    self.assertBounds(); b.assertBounds();
                    var r: Field(mag + @TypeOf(b).magnitude) = undefined;
                    inline for (0..5) |i| r.limbs[i] = self.limbs[i] + b.limbs[i];
                    return r;
                }
                pub inline fn sub(self: Self, b: anytype) Field(mag + 2 * @TypeOf(b).magnitude) {
                    @setRuntimeSafety(checked);
                    self.assertBounds(); b.assertBounds();
                    const bm = @TypeOf(b).magnitude;
                    const modulus = [5]u64{ (1 << 52) - complement, mask, mask, mask, top };
                    var r: Field(mag + 2 * bm) = undefined;
                    inline for (0..5) |i| r.limbs[i] = self.limbs[i] + 2 * bm * modulus[i] - b.limbs[i];
                    return r;
                }
                pub inline fn mul(self: Self, b: anytype) Field(1) {
                    @setRuntimeSafety(checked);
                    self.assertBounds(); b.assertBounds();
                    var t: [10]u128 = @splat(0);
                    inline for (0..5) |i| inline for (0..5) |j| { t[i+j] += @as(u128,self.limbs[i]) * b.limbs[j]; };
                    return product(t);
                }
                pub inline fn square(self: Self) Field(1) {
                    @setRuntimeSafety(checked);
                    self.assertBounds();
                    var t: [10]u128 = @splat(0);
                    inline for (0..5) |i| {
                        t[2*i] += @as(u128,self.limbs[i]) * self.limbs[i];
                        inline for (i+1..5) |j| t[i+j] += 2 * @as(u128,self.limbs[i]) * self.limbs[j];
                    }
                    return product(t);
                }
            };
        }
        inline fn product(input: [10]u128) Field(1) {
            @setRuntimeSafety(checked);
            var t = input;
            // Carry before folding: every high digit is then below 2^52.
            inline for (0..9) |i| { t[i+1] += t[i] >> 52; t[i] &= mask; }
            var low: [5]u128 = undefined;
            inline for (0..5) |i| low[i] = t[i] + t[i+5] * (16 * @as(u128,complement));
            return finish(low);
        }
        inline fn finish(input: [5]u128) Field(1) {
            @setRuntimeSafety(checked);
            var t = input;
            // The first top fold leaves at most a carry cascade; two more
            // passes absorb it even for the largest supported magnitude.
            inline for (0..3) |_| {
                inline for (0..4) |i| { t[i+1] += t[i] >> 52; t[i] &= mask; }
                const high = t[4] >> 48; t[4] &= top; t[0] += high * complement;
            }
            var result: Field(1) = undefined;
            inline for (0..5) |i| result.limbs[i] = @intCast(t[i]);
            result.assertBounds();
            return result;
        }
    };
}

test "million deterministic checked/unchecked convolutions and bounded chains" {
    const C = Kernel(true).Field(1); const U = Kernel(false).Field(1);
    var rng = std.Random.DefaultPrng.init(0x6f70656e3532);
    for (0..1_000_000) |_| {
        const a = rng.random().int(u256); const b = rng.random().int(u256);
        const expected: u256 = @intCast((@as(u512,a)*b)%p);
        const x=C.fromInt(a);const y=C.fromInt(b);
        try std.testing.expectEqual(expected,x.mul(y).integer());
        try std.testing.expectEqual(expected,U.fromInt(a).mul(U.fromInt(b)).integer());
        try std.testing.expectEqual(@as(u256,@intCast((@as(u512,a)*a)%p)),x.square().integer());
        try std.testing.expectEqual(a%p,x.add(y).sub(y).integer());
    }
    const max = C{.limbs=.{mask,mask,mask,mask,top}};
    const m2=max.add(max);const m4=m2.add(m2);const m8=m4.add(m4);
    const v=m8.integer();
    try std.testing.expectEqual(@as(u256,@intCast((@as(u512,v)*v)%p)),m8.mul(m8).integer());
    try std.testing.expectEqual(m8.mul(m8).integer(),m8.square().integer());
}
