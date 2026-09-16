//! Experimental variable-time public-input secp256k1. No secret-key operations.
const std = @import("std");
const p: u256 = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
const n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
const g = Point{ .x = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798, .y = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8 };
pub const Error = error{ MalformedInput, InvalidScalar, Infinity };
// p = 2^256 - (2^32 + 977). Three folds bound the result below 2^256;
// a final subtraction canonicalizes it. No general division is needed here.
fn reduceField(w: u512) u256 {
    const mask: u512 = std.math.maxInt(u256);
    const complement: u512 = 0x1000003d1;
    var r = (w & mask) + (w >> 256) * complement;
    r = (r & mask) + (r >> 256) * complement;
    r = (r & mask) + (r >> 256) * complement;
    if (r >= p) r -= p;
    return @intCast(r);
}
fn add(a: u256, b: u256) u256 {
    const sum = @as(u257, a) + b;
    return @intCast(if (sum >= p) sum - p else sum);
}
fn sub(a: u256, b: u256) u256 {
    return if (a >= b) a - b else p - (b - a);
}
fn mul(a: u256, b: u256) u256 {
    return reduceField(@as(u512, a) * b);
}
fn times(a: u256, comptime b: u256) u256 {
    const twice = add(a, a);
    return switch (b) {
        2 => twice,
        3 => add(twice, a),
        4 => add(twice, twice),
        8 => blk: {
            const four = add(twice, twice);
            break :blk add(four, four);
        },
        else => @compileError("unsupported small multiplier"),
    };
}
fn pow(a: u256, exponent: u256, modulus: u256) u256 {
    var result: u256 = 1;
    var base = a;
    var e = exponent;
    while (e != 0) : (e >>= 1) {
        if (e & 1 != 0) result = if (modulus == p) mul(result, base) else @intCast((@as(u512, result) * base) % modulus);
        base = if (modulus == p) mul(base, base) else @intCast((@as(u512, base) * base) % modulus);
    }
    return result;
}
// u = input*x (mod modulus) is maintained by binary subtraction and halving.
// Coefficients stay below the odd modulus; x+modulus fits u257, and its
// half fits u256. Inputs are public and the iteration count is variable.
pub fn inverse(input: u256, modulus: u256) Error!u256 {
    if (input == 0 or input >= modulus) return error.InvalidScalar;
    var u = input;
    var v = modulus;
    var x: u256 = 1;
    var y: u256 = 0;
    while (u != 1 and v != 1) {
        if (u == 0 or v == 0) return error.InvalidScalar;
        while (u & 1 == 0) {
            u >>= 1;
            x = halfCoefficient(x, modulus);
        }
        while (v & 1 == 0) {
            v >>= 1;
            y = halfCoefficient(y, modulus);
        }
        if (u >= v) {
            u -= v;
            x = if (x >= y) x - y else modulus - (y - x);
        } else {
            v -= u;
            y = if (y >= x) y - x else modulus - (x - y);
        }
    }
    return if (u == 1) x else y;
}
fn halfCoefficient(x: u256, modulus: u256) u256 {
    return if (x & 1 == 0) x >> 1 else @intCast((@as(u257, x) + modulus) >> 1);
}
fn read(b: []const u8) u256 {
    var r: u256 = 0;
    for (b) |v| {
        r = (r << 8) | v;
    }
    return r;
}
fn write(a: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, a, .big);
    return out;
}
const Point = struct {
    x: u256 = 0,
    y: u256 = 1,
    z: u256 = 1,
    fn infinity() Point {
        return .{ .z = 0 };
    }
    fn double(self: Point) Point {
        if (self.z == 0 or self.y == 0) return infinity();
        const a = mul(self.x, self.x);
        const b = mul(self.y, self.y);
        const c = mul(b, b);
        const xb = add(self.x, b);
        const d = times(sub(sub(mul(xb, xb), a), c), 2);
        const e = times(a, 3);
        const f = mul(e, e);
        const x = sub(f, times(d, 2));
        return .{ .x = x, .y = sub(mul(e, sub(d, x)), times(c, 8)), .z = times(mul(self.y, self.z), 2) };
    }
    fn plus(self: Point, q: Point) Point {
        if (self.z == 0) return q;
        if (q.z == 0) return self;
        const z1 = mul(self.z, self.z);
        const z2 = mul(q.z, q.z);
        const ux1 = mul(self.x, z2);
        const ux2 = mul(q.x, z1);
        const s1 = mul(self.y, mul(q.z, z2));
        const s2 = mul(q.y, mul(self.z, z1));
        if (ux1 == ux2) return if (s1 == s2) self.double() else infinity();
        const h = sub(ux2, ux1);
        const i = mul(times(h, 2), times(h, 2));
        const j = mul(h, i);
        const r = times(sub(s2, s1), 2);
        const v = mul(ux1, i);
        const x = sub(sub(mul(r, r), j), times(v, 2));
        return .{ .x = x, .y = sub(mul(r, sub(v, x)), times(mul(s1, j), 2)), .z = times(mul(mul(self.z, q.z), h), 2) };
    }
    // q is affine (Z=1) or infinity. Equality is compared after scaling
    // q into this point's Jacobian coordinates, never by raw limbs.
    fn mixed(self: Point, q: Point) Point {
        if (self.z == 0) return q;
        if (q.z == 0) return self;
        const zz = mul(self.z, self.z);
        const h = sub(mul(q.x, zz), self.x);
        const d = sub(mul(q.y, mul(self.z, zz)), self.y);
        if (h == 0) return if (d == 0) self.double() else infinity();
        const hh = mul(h, h);
        const hhh = mul(h, hh);
        const v = mul(self.x, hh);
        const x = sub(sub(mul(d, d), hhh), times(v, 2));
        return .{ .x = x, .y = sub(mul(d, sub(v, x)), mul(self.y, hhh)), .z = mul(self.z, h) };
    }
    fn affine(self: Point) Error!Point {
        if (self.z == 0) return error.Infinity;
        const zi = try inverse(self.z, p);
        const z2 = mul(zi, zi);
        return .{ .x = mul(self.x, z2), .y = mul(self.y, mul(z2, zi)) };
    }
};
const Digits = struct { values: [257]i8 = @splat(0), len: usize = 0 };
pub fn recode(scalar: u256) Digits {
    var out: Digits = .{};
    // A negative low digit can carry into bit 256; u257 holds that carry.
    var remaining: u257 = scalar;
    while (remaining != 0) {
        if (remaining & 1 != 0) {
            const residue: i16 = @intCast(remaining & 31);
            const digit: i16 = if (residue > 16) residue - 32 else residue;
            out.values[out.len] = @intCast(digit);
            if (digit < 0) remaining += @as(u257, @intCast(-digit)) else remaining -= @as(u257, @intCast(digit));
        }
        remaining >>= 1;
        out.len += 1;
    }
    return out;
}
fn oddTable(point: Point) [8]Point {
    var table: [8]Point = undefined;
    table[0] = point;
    const step = point.double();
    for (1..8) |i| table[i] = table[i - 1].plus(step);
    var prefix: [8]u256 = undefined;
    var product: u256 = 1;
    for (table, 0..) |entry, i| {
        prefix[i] = product;
        if (entry.z != 0) product = mul(product, entry.z);
    }
    var reciprocal = inverse(product, p) catch unreachable;
    var i: usize = 8;
    while (i != 0) {
        i -= 1;
        if (table[i].z == 0) continue;
        const zi = mul(reciprocal, prefix[i]);
        reciprocal = mul(reciprocal, table[i].z);
        const zz = mul(zi, zi);
        table[i] = .{ .x = mul(table[i].x, zz), .y = mul(table[i].y, mul(zz, zi)) };
    }
    return table;
}
const generator_table = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk oddTable(g);
};
fn signedPoint(table: *const [8]Point, digit: i8) Point {
    const magnitude: u8 = @intCast(if (digit < 0) -@as(i16, digit) else digit);
    var point = table[(magnitude - 1) / 2];
    if (digit < 0) point.y = sub(0, point.y);
    return point;
}
fn joint(a: u256, point: Point, b: u256) Point {
    const left = recode(a);
    const right = recode(b);
    const table = if (b == 0) [_]Point{Point.infinity()} ** 8 else oddTable(point);
    var result = Point.infinity();
    var i = @max(left.len, right.len);
    while (i != 0) {
        i -= 1;
        result = result.double();
        if (left.values[i] != 0) result = result.mixed(signedPoint(&generator_table, left.values[i]));
        if (right.values[i] != 0) result = result.mixed(signedPoint(&table, right.values[i]));
    }
    return result;
}
fn schnorrPoint(s: u256, point: Point, e: u256) Point {
    return joint(s, point, if (e == 0) 0 else n - e);
}
fn lift(x: u256, odd: bool) Error!Point {
    if (x >= p) return error.MalformedInput;
    const rhs = add(mul(mul(x, x), x), 7);
    var y = pow(rhs, (p + 1) / 4, p);
    if (mul(y, y) != rhs) return error.MalformedInput;
    if ((y & 1 != 0) != odd) y = p - y;
    return .{ .x = x, .y = y };
}
/// Validated SEC1 public key; callers should construct it with the parsers.
pub const PublicKey = struct {
    point: Point,
    pub fn compressed(self: PublicKey) [33]u8 {
        return [_]u8{2 + @as(u8, @intCast(self.point.y & 1))} ++ write(self.point.x);
    }
};
/// Parse compressed, uncompressed or parity-consistent hybrid SEC1 bytes.
pub fn parsePublicKey(b: []const u8) Error!PublicKey {
    if (b.len == 33 and (b[0] == 2 or b[0] == 3)) return .{ .point = try lift(read(b[1..]), b[0] == 3) };
    if (b.len != 65 or (b[0] != 4 and b[0] != 6 and b[0] != 7)) return error.MalformedInput;
    const x = read(b[1..33]);
    const y = read(b[33..]);
    if (x >= p or y >= p or mul(y, y) != add(mul(mul(x, x), x), 7)) return error.MalformedInput;
    if (b[0] != 4 and (y & 1) != (b[0] & 1)) return error.MalformedInput;
    return .{ .point = .{ .x = x, .y = y } };
}
/// Lift exactly 32 bytes to an even-y public point.
pub fn parseXOnly(b: []const u8) Error!PublicKey {
    if (b.len != 32) return error.MalformedInput;
    return .{ .point = try lift(read(b), false) };
}
const Scalar = struct { value: u256, valid: bool };
fn derInt(b: []const u8, pos: *usize) Error!Scalar {
    if (pos.* + 2 > b.len or b[pos.*] != 2) return error.MalformedInput;
    const len: usize = b[pos.* + 1];
    pos.* += 2;
    if (len == 0 or pos.* + len > b.len) return error.MalformedInput;
    const v = b[pos.*..][0..len];
    pos.* += len;
    if (len > 1 and ((v[0] == 0 and v[1] & 128 == 0) or (v[0] == 255 and v[1] & 128 != 0))) return error.MalformedInput;
    if (v[0] & 128 != 0) return .{ .value = 0, .valid = false };
    const unsigned = if (v[0] == 0) v[1..] else v;
    if (unsigned.len > 32) return .{ .value = 0, .valid = false };
    const value = read(unsigned);
    return .{ .value = value, .valid = value > 0 and value < n };
}
fn parseDer(b: []const u8) Error!struct { r: Scalar, s: Scalar } {
    if (b.len < 8 or b.len > 72 or b[0] != 0x30 or b[1] != b.len - 2) return error.MalformedInput;
    var pos: usize = 2;
    const r = try derInt(b, &pos);
    const s = try derInt(b, &pos);
    if (pos != b.len) return error.MalformedInput;
    return .{ .r = r, .s = s };
}
/// Verify a 32-byte digest and bare DER signature, accepting valid high-S.
pub fn verifyEcdsa(key: []const u8, digest: []const u8, signature: []const u8) Error!bool {
    if (digest.len != 32) return error.MalformedInput;
    const pubkey = try parsePublicKey(key);
    const sig = try parseDer(signature);
    if (!sig.r.valid or !sig.s.valid) return false;
    const w = try inverse(sig.s.value, n);
    const u: u256 = @intCast((@as(u512, read(digest)) * w) % n);
    const v: u256 = @intCast((@as(u512, sig.r.value) * w) % n);
    const q = joint(u, pubkey.point, v);
    return ecdsaXMatches(q, sig.r.value);
}
// Since 0 <= affine x < p < 2n, only r and r+n can reduce to r modulo n.
// The widened addition must be checked before any field reduction.
fn ecdsaXMatches(q: Point, r: u256) bool {
    if (q.z == 0 or r >= n) return false;
    const z2 = mul(q.z, q.z);
    if (q.x == mul(r, z2)) return true;
    const sum = @as(u257, r) + n;
    return sum < p and q.x == mul(@intCast(sum), z2);
}
/// Caller-owned normalized DER, with no allocator requirement.
pub const DerSignature = struct {
    bytes: [72]u8,
    len: usize,
    pub fn slice(self: *const DerSignature) []const u8 {
        return self.bytes[0..self.len];
    }
};
fn encodeInt(out: []u8, value: u256) usize {
    const b = write(value);
    var start: usize = 0;
    while (start < 31 and b[start] == 0) : (start += 1) {}
    const pad: usize = if (b[start] & 128 != 0) 1 else 0;
    out[0] = 2;
    out[1] = @intCast(32 - start + pad);
    if (pad == 1) out[2] = 0;
    @memcpy(out[2 + pad ..][0 .. 32 - start], b[start..]);
    return 2 + pad + 32 - start;
}
/// Normalize an in-range DER signature to low-S.
pub fn normalizeLowS(signature: []const u8) Error!DerSignature {
    const sig = try parseDer(signature);
    if (!sig.r.valid or !sig.s.valid) return error.InvalidScalar;
    var result: DerSignature = .{ .bytes = undefined, .len = 2 };
    result.len += encodeInt(result.bytes[result.len..], sig.r.value);
    result.len += encodeInt(result.bytes[result.len..], if (sig.s.value > n / 2) n - sig.s.value else sig.s.value);
    result.bytes[0] = 0x30;
    result.bytes[1] = @intCast(result.len - 2);
    return result;
}
/// BIP340 verification for arbitrary-length public messages.
pub fn verifySchnorr(key: []const u8, message: []const u8, signature: []const u8) Error!bool {
    if (signature.len != 64) return error.MalformedInput;
    const pubkey = try parseXOnly(key);
    const r = read(signature[0..32]);
    const s = read(signature[32..]);
    if (r >= p or s >= n) return false;
    const Sha = std.crypto.hash.sha2.Sha256;
    var tag: [32]u8 = undefined;
    Sha.hash("BIP0340/challenge", &tag, .{});
    var h = Sha.init(.{});
    h.update(&tag);
    h.update(&tag);
    h.update(signature[0..32]);
    h.update(key);
    h.update(message);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const e = read(&digest) % n;
    const q = schnorrPoint(s, pubkey.point, e).affine() catch return false;
    return q.y & 1 == 0 and q.x == r;
}
pub const TweakResult = struct { output_xonly: [32]u8, parity: u8 };
/// Add a raw scalar to an even-y x-only key. Zero tweak is valid.
pub fn addXOnlyTweak(key: []const u8, tweak: []const u8) Error!TweakResult {
    if (tweak.len != 32) return error.MalformedInput;
    const pubkey = try parseXOnly(key);
    const t = read(tweak);
    if (t >= n) return error.InvalidScalar;
    const q = try joint(t, pubkey.point, 1).affine();
    return .{ .output_xonly = write(q.x), .parity = @intCast(q.y & 1) };
}
/// Check both coordinate and parity of a tweaked public key.
pub fn checkXOnlyTweak(key: []const u8, tweak: []const u8, output: []const u8, parity: u8) Error!bool {
    if (output.len != 32 or parity > 1) return error.MalformedInput;
    const r = try addXOnlyTweak(key, tweak);
    return std.mem.eql(u8, output, &r.output_xonly) and parity == r.parity;
}
