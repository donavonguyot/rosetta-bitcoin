//! Experimental variable-time public-input secp256k1. No secret-key operations.
//! Verification handles public data. Constant-time execution is not a goal.
//! Each function disables runtime checks. Zig 0.16 still emits them for an
//! imported module when the executable root is ReleaseSafe, even though this
//! module is built ReleaseFast. Vectors, mutations, and the field tests cover it.
const std = @import("std");
const curve_profile = @import("curve_options").curve_profile;
const p: u256 = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
const n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
const g = Point{ .x = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798, .y = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8 };
pub const Error = error{ MalformedInput, InvalidScalar, Infinity };
const ProfileSlot = enum(u3) { fe_inv, fe_mul_sqr, point_double, point_add, to_affine, table_hit };
var profile_counts: [6]u64 = @splat(0);
fn profileNote(slot: ProfileSlot) void {
    @setRuntimeSafety(false);
    if (comptime !curve_profile) return;
    _ = @atomicRmw(u64, &profile_counts[@intFromEnum(slot)], .Add, 1, .monotonic);
}
pub const ProfileCounts = struct {
    fe_inv: u64,
    fe_mul_sqr: u64,
    point_double: u64,
    point_add: u64,
    to_affine: u64,
    table_hit: u64,
};
pub fn profileReset() void {
    @setRuntimeSafety(false);
    for (&profile_counts) |*slot| @atomicStore(u64, slot, 0, .monotonic);
}
pub fn profileCounts() ProfileCounts {
    @setRuntimeSafety(false);
    return .{
        .fe_inv = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.fe_inv)], .monotonic),
        .fe_mul_sqr = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.fe_mul_sqr)], .monotonic),
        .point_double = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.point_double)], .monotonic),
        .point_add = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.point_add)], .monotonic),
        .to_affine = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.to_affine)], .monotonic),
        .table_hit = @atomicLoad(u64, &profile_counts[@intFromEnum(ProfileSlot.table_hit)], .monotonic),
    };
}
pub fn benchBasePoint() Point {
    @setRuntimeSafety(false);
    return g;
}
pub fn benchFeMul(a: u256, b: u256) u256 {
    @setRuntimeSafety(false);
    return mul(a, b);
}
pub fn benchFeSqr(a: u256) u256 {
    @setRuntimeSafety(false);
    return mul(a, a);
}
pub fn benchFeInv(a: u256) Error!u256 {
    @setRuntimeSafety(false);
    return inverse(a, p);
}
pub fn benchFeNormalize(a: u256) u256 {
    @setRuntimeSafety(false);
    return if (a >= p) a - p else a;
}
pub fn benchScMul(a: u256, b: u256) u256 {
    @setRuntimeSafety(false);
    return reduceScalar(@as(u512, a) * b);
}
pub fn benchScInv(a: u256) Error!u256 {
    @setRuntimeSafety(false);
    return inverse(a, n);
}
pub fn benchRead(bytes: *const [32]u8) u256 {
    @setRuntimeSafety(false);
    return read(bytes);
}
pub fn benchPointDouble(q: Point) Point {
    @setRuntimeSafety(false);
    return q.double();
}
pub fn benchPointAdd(a: Point, b: Point) Point {
    @setRuntimeSafety(false);
    return a.plus(b);
}
pub fn benchToAffine(q: Point) Error!Point {
    @setRuntimeSafety(false);
    return q.affine();
}
pub fn benchScalarMulFixed(k: u256) Point {
    @setRuntimeSafety(false);
    return generatorMultiply(k);
}
pub fn benchScalarMulVar(q: Point, k: u256) Point {
    @setRuntimeSafety(false);
    return joint(0, q, k);
}
pub fn benchDoubleScalar(a: u256, q: Point, b: u256) Point {
    @setRuntimeSafety(false);
    return joint(a, q, b);
}
// p = 2^256 - (2^32 + 977). Three folds bound the result below 2^256;
// a final subtraction canonicalizes it. No general division is needed here.
fn reduceField(w: u512) u256 {
    @setRuntimeSafety(false);
    const mask: u512 = std.math.maxInt(u256);
    const complement: u512 = 0x1000003d1;
    var r = (w & mask) + (w >> 256) * complement;
    r = (r & mask) + (r >> 256) * complement;
    r = (r & mask) + (r >> 256) * complement;
    if (r >= p) r -= p;
    return @intCast(r);
}
fn add(a: u256, b: u256) u256 {
    @setRuntimeSafety(false);
    const sum = @as(u257, a) + b;
    return @intCast(if (sum >= p) sum - p else sum);
}
fn sub(a: u256, b: u256) u256 {
    @setRuntimeSafety(false);
    return if (a >= b) a - b else p - (b - a);
}
fn mul(a: u256, b: u256) u256 {
    @setRuntimeSafety(false);
    profileNote(.fe_mul_sqr);
    return reduceField(@as(u512, a) * b);
}
fn times(a: u256, comptime b: u256) u256 {
    @setRuntimeSafety(false);
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

// u = input*x (mod modulus) is maintained by binary subtraction and halving.
// Coefficients remain below the odd modulus. The odd half is formed from
// two shifted values plus one, with sum below the modulus. Inputs are public.
fn inverse(input: u256, modulus: u256) Error!u256 {
    @setRuntimeSafety(false);
    if (modulus == p) profileNote(.fe_inv);
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
    @setRuntimeSafety(false);
    return if (x & 1 == 0) x >> 1 else (x >> 1) + (modulus >> 1) + 1;
}
fn read(b: []const u8) u256 {
    @setRuntimeSafety(false);
    var r: u256 = 0;
    for (b) |v| {
        r = (r << 8) | v;
    }
    return r;
}
fn write(a: u256) [32]u8 {
    @setRuntimeSafety(false);
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, a, .big);
    return out;
}
pub const Point = struct {
    x: u256 = 0,
    y: u256 = 1,
    z: u256 = 1,
    fn infinity() Point {
        @setRuntimeSafety(false);
        return .{ .z = 0 };
    }
    fn double(self: Point) Point {
        @setRuntimeSafety(false);
        profileNote(.point_double);
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
        @setRuntimeSafety(false);
        profileNote(.point_add);
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
        @setRuntimeSafety(false);
        profileNote(.point_add);
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
        @setRuntimeSafety(false);
        profileNote(.to_affine);
        if (self.z == 0) return error.Infinity;
        const zi = try inverse(self.z, p);
        const z2 = mul(zi, zi);
        return .{ .x = mul(self.x, z2), .y = mul(self.y, mul(z2, zi)) };
    }
};

fn oddTableWidth(point: Point, comptime width: usize) [1 << (width - 2)]Point {
    @setRuntimeSafety(false);
    const size = 1 << (width - 2);
    var table: [size]Point = undefined;
    table[0] = point;
    const step = point.double();
    for (1..size) |i| table[i] = table[i - 1].plus(step);
    var prefix: [size]u256 = undefined;
    var product: u256 = 1;
    for (table, 0..) |entry, i| {
        prefix[i] = product;
        if (entry.z != 0) product = mul(product, entry.z);
    }
    var reciprocal = inverse(product, p) catch unreachable;
    var i: usize = size;
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
const PackedPoint = struct { x: u256, y: u256 };
fn unpackTable(comptime data: []const u8) [data.len / 64]PackedPoint {
    @setRuntimeSafety(false);
    @setEvalBranchQuota(20_000_000);
    var out: [data.len / 64]PackedPoint = undefined;
    for (&out, 0..) |*entry, i| entry.* = .{ .x = std.mem.readInt(u256, data[i * 64 ..][0..32], .big), .y = std.mem.readInt(u256, data[i * 64 + 32 ..][0..32], .big) };
    return out;
}
const generator_table = unpackTable(@embedFile("generator.bin"));

fn signedPoint(table: anytype, digit: i16) Point {
    @setRuntimeSafety(false);
    profileNote(.table_hit);
    const magnitude: u16 = @intCast(if (digit < 0) -@as(i16, digit) else digit);
    const stored = table[(magnitude - 1) / 2];
    var point = Point{ .x = stored.x, .y = stored.y, .z = if (@hasField(@TypeOf(stored), "z")) stored.z else 1 };
    if (digit < 0) point.y = sub(0, point.y);
    return point;
}
// Constants are generated by tools/derive_constants.py from cube roots and exact Gauss reduction.
const beta: u256 = 0x7ae96a2b657c07106e64479eac3434e99cf0497512f58995c1396c28719501ee;
const lambda: u256 = 0x5363ad4cc05c30e0a5261c028812645a122e22ea20816678df02967c1b23bd72;
const basis_a: [2]i512 = .{ -64502973549206556628585045361533709077, 303414439467246543595250775667605759171 };
const basis_b: [2]i512 = .{ -367917413016453100223835821029139468248, -64502973549206556628585045361533709077 };
fn nearestQuotient(value: i512) i512 {
    @setRuntimeSafety(false);
    const magnitude = if (value < 0) -value else value;
    const q = @divTrunc(magnitude + @as(i512, n / 2), @as(i512, n));
    return if (value < 0) -q else q;
}
fn splitScalar(k: u256) [2]i256 {
    @setRuntimeSafety(false);
    const c1 = nearestQuotient(@as(i512, k) * basis_b[1]);
    const c2 = nearestQuotient(-@as(i512, k) * basis_a[1]);
    const first = @as(i512, k) - c1 * basis_a[0] - c2 * basis_b[0];
    const second = -c1 * basis_a[1] - c2 * basis_b[1];
    std.debug.assert(@abs(first) < (@as(u512, 1) << 129) and @abs(second) < (@as(u512, 1) << 129));
    return .{ @intCast(first), @intCast(second) };
}
const ShortDigits = struct { values: [131]i16 = @splat(0), len: usize = 0 };
fn recodeSigned(k: i256, comptime width: usize) ShortDigits {
    @setRuntimeSafety(false);
    var out: ShortDigits = .{};
    var remaining: u130 = @intCast(@abs(k));
    while (remaining != 0) {
        if (remaining & 1 != 0) {
            const residue: i32 = @intCast(remaining & ((@as(u130, 1) << width) - 1));
            const digit = if (residue > (1 << (width - 1))) residue - (1 << width) else residue;
            out.values[out.len] = @intCast(if (k < 0) -digit else digit);
            if (digit < 0) remaining += @as(u130, @intCast(-digit)) else remaining -= @as(u130, @intCast(digit));
        }
        remaining >>= 1;
        out.len += 1;
    }
    return out;
}
fn endomorphism(q: Point) Point {
    @setRuntimeSafety(false);
    return .{ .x = mul(beta, q.x), .y = q.y, .z = q.z };
}
const phi_generator_table = unpackTable(@embedFile("phi-generator.bin"));

fn joint(a: u256, point: Point, b: u256) Point {
    @setRuntimeSafety(false);
    const left = splitScalar(a);
    const right = splitScalar(b);
    const streams = [_]ShortDigits{ recodeSigned(left[0], g_width), recodeSigned(left[1], g_width), recodeSigned(right[0], p_width), recodeSigned(right[1], p_width) };
    const common = commonZTable(if (b == 0) Point.infinity() else point, p_width);
    const table = common.table;
    const scale2 = mul(common.scale, common.scale);
    const scale3 = mul(scale2, common.scale);
    var phi_table = table;
    for (&phi_table) |*q| q.* = endomorphism(q.*);
    var length: usize = 0;
    for (streams) |d| length = @max(length, d.len);
    var result = Point.infinity();
    while (length != 0) {
        length -= 1;
        result = result.double();
        if (streams[0].values[length] != 0) result = result.mixed(scaleAffine(signedPoint(&generator_table, streams[0].values[length]), scale2, scale3));
        if (streams[1].values[length] != 0) result = result.mixed(scaleAffine(signedPoint(&phi_generator_table, streams[1].values[length]), scale2, scale3));
        if (streams[2].values[length] != 0) result = result.mixed(signedPoint(&table, streams[2].values[length]));
        if (streams[3].values[length] != 0) result = result.mixed(signedPoint(&phi_table, streams[3].values[length]));
    }
    result.z = mul(result.z, common.scale);
    return result;
}

fn schnorrPoint(s: u256, point: Point, e: u256) Point {
    @setRuntimeSafety(false);
    return joint(s, point, if (e == 0) 0 else n - e);
}
fn lift(x: u256, odd: bool) Error!Point {
    @setRuntimeSafety(false);
    if (x >= p) return error.MalformedInput;
    const rhs = add(mul(mul(x, x), x), 7);
    var y = sqrtPower(rhs);
    if (mul(y, y) != rhs) return error.MalformedInput;
    if ((y & 1 != 0) != odd) y = p - y;
    return .{ .x = x, .y = y };
}
/// Validated SEC1 public key; callers should construct it with the parsers.
pub const PublicKey = struct {
    point: Point,
    pub fn compressed(self: PublicKey) [33]u8 {
        @setRuntimeSafety(false);
        return [_]u8{2 + @as(u8, @intCast(self.point.y & 1))} ++ write(self.point.x);
    }
};
/// Parse compressed, uncompressed or parity-consistent hybrid SEC1 bytes.
pub fn parsePublicKey(b: []const u8) Error!PublicKey {
    @setRuntimeSafety(false);
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
    @setRuntimeSafety(false);
    if (b.len != 32) return error.MalformedInput;
    return .{ .point = try lift(read(b), false) };
}
const Scalar = struct { value: u256, valid: bool };
fn derInt(b: []const u8, pos: *usize) Error!Scalar {
    @setRuntimeSafety(false);
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
    @setRuntimeSafety(false);
    if (b.len < 8 or b.len > 72 or b[0] != 0x30 or b[1] != b.len - 2) return error.MalformedInput;
    var pos: usize = 2;
    const r = try derInt(b, &pos);
    const s = try derInt(b, &pos);
    if (pos != b.len) return error.MalformedInput;
    return .{ .r = r, .s = s };
}
/// Verify a 32-byte digest and bare DER signature, accepting valid high-S.
pub fn verifyEcdsa(key: []const u8, digest: []const u8, signature: []const u8) Error!bool {
    @setRuntimeSafety(false);
    if (digest.len != 32) return error.MalformedInput;
    const pubkey = try parsePublicKey(key);
    const sig = try parseDer(signature);
    if (!sig.r.valid or !sig.s.valid) return false;
    const w = try inverse(sig.s.value, n);
    const u: u256 = reduceScalar(@as(u512, read(digest)) * w);
    const v: u256 = reduceScalar(@as(u512, sig.r.value) * w);
    const q = joint(u, pubkey.point, v);
    return ecdsaXMatches(q, sig.r.value);
}
// Since 0 <= affine x < p < 2n, only r and r+n can reduce to r modulo n.
// The widened addition must be checked before any field reduction.
fn ecdsaXMatches(q: Point, r: u256) bool {
    @setRuntimeSafety(false);
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
        @setRuntimeSafety(false);
        return self.bytes[0..self.len];
    }
};
fn encodeInt(out: []u8, value: u256) usize {
    @setRuntimeSafety(false);
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
    @setRuntimeSafety(false);
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
    @setRuntimeSafety(false);
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
    const e = scalar256(read(&digest));
    const q = schnorrPoint(s, pubkey.point, e).affine() catch return false;
    return q.y & 1 == 0 and q.x == r;
}
pub const TweakResult = struct { output_xonly: [32]u8, parity: u8 };
/// Add a raw scalar to an even-y x-only key. Zero tweak is valid.
pub fn addXOnlyTweak(key: []const u8, tweak: []const u8) Error!TweakResult {
    @setRuntimeSafety(false);
    if (tweak.len != 32) return error.MalformedInput;
    const pubkey = try parseXOnly(key);
    const t = read(tweak);
    if (t >= n) return error.InvalidScalar;
    const q = try generatorMultiply(t).mixed(pubkey.point).affine();
    return .{ .output_xonly = write(q.x), .parity = @intCast(q.y & 1) };
}
/// Check both coordinate and parity of a tweaked public key.
pub fn checkXOnlyTweak(key: []const u8, tweak: []const u8, output: []const u8, parity: u8) Error!bool {
    @setRuntimeSafety(false);
    if (output.len != 32 or parity > 1) return error.MalformedInput;
    const r = try addXOnlyTweak(key, tweak);
    return std.mem.eql(u8, output, &r.output_xonly) and parity == r.parity;
}
test {
    _ = @import("tests.zig");
}

test "field reduction agrees with general division at boundaries and random wide values" {
    const boundaries = [_]u512{ 0, 1, p - 1, p, p + 1, std.math.maxInt(u256), @as(u512, p - 1) * (p - 1), std.math.maxInt(u512) };
    for (boundaries) |value| try std.testing.expectEqual(@as(u256, @intCast(value % p)), reduceField(value));
    var random = std.Random.DefaultPrng.init(0x534543503235364b);
    for (0..2048) |_| {
        const value = random.random().int(u512);
        try std.testing.expectEqual(@as(u256, @intCast(value % p)), reduceField(value));
    }
}

fn expectSamePoint(actual: Point, expected: @import("test_original.zig").Point) !void {
    @setRuntimeSafety(false);
    if (expected.z == 0) return std.testing.expectEqual(@as(u256, 0), actual.z);
    const a = try actual.affine();
    const b = try expected.affine();
    try std.testing.expectEqual(b.x, a.x);
    try std.testing.expectEqual(b.y, a.y);
}

test "campaign 10000 independent arithmetic comparisons and signed digits" {
    const old = @import("test_original.zig");
    var rng = std.Random.DefaultPrng.init(0x574e41465f303035);
    const random = rng.random();
    for (0..10_000) |i| {
        const scalar = random.int(u256);
        const k = scalar % (n - 1) + 1;
        const inverse_n = try inverse(k, n);
        try std.testing.expectEqual(old.pow(k, n - 2, n), inverse_n);
        try std.testing.expectEqual(@as(u512, 1), (@as(u512, k) * inverse_n) % n);
        const x = random.int(u256) % (p - 1) + 1;
        try std.testing.expectEqual(old.pow(x, p - 2, p), try inverse(x, p));
        const digits = @import("test_residual_baseline.zig").recode(scalar);
        var reconstructed: i512 = 0;
        for (digits.values, 0..) |digit, bit| {
            reconstructed += @as(i512, digit) << @as(u9, @intCast(bit));
            if (digit != 0) {
                try std.testing.expect(@abs(digit) <= 15 and @abs(digit) % 2 == 1);
                for (bit + 1..@min(bit + 5, 257)) |next| try std.testing.expectEqual(@as(i8, 0), digits.values[next]);
            }
        }
        try std.testing.expectEqual(@as(i512, scalar), reconstructed);
        const other = random.int(u256) % n;
        // Vary the base as well as both scalars; rescale to a nonunit Z.
        const base = try old.g.multiply(@as(u256, @intCast(i)) + 1).affine();
        const z = x;
        const zz = mul(z, z);
        const point = Point{ .x = mul(base.x, zz), .y = mul(base.y, mul(zz, z)), .z = z };
        try expectSamePoint(joint(k, point, other), old.g.multiply(k).plus(base.multiply(other)));
        try expectSamePoint(point.double(), (old.Point{ .x = point.x, .y = point.y, .z = z }).double());
    }
}

test "campaign inverse carries and private ECDSA coordinate comparison" {
    for ([_]u256{ p, n }) |modulus| {
        try std.testing.expectError(error.InvalidScalar, inverse(0, modulus));
        try std.testing.expectError(error.InvalidScalar, inverse(modulus, modulus));
        for ([_]u256{ 1, 2, modulus - 2, modulus - 1 }) |v| {
            const inv = try inverse(v, modulus);
            try std.testing.expectEqual(@as(u512, 1), (@as(u512, v) * inv) % modulus);
            try std.testing.expectEqual(@as(u512, v), (@as(u512, halfCoefficient(v, modulus)) * 2) % modulus);
        }
    }
    for ([_]u256{ 1, 2, p - 1 }) |z| {
        const zz = mul(z, z);
        for ([_]u256{ 0, 1, p - n - 1 }) |r| {
            const x = @as(u257, r) + n;
            try std.testing.expect(ecdsaXMatches(.{ .x = mul(@intCast(x), zz), .z = z }, r));
            try std.testing.expect(ecdsaXMatches(.{ .x = mul(r, zz), .z = z }, r));
        }
        try std.testing.expect(!ecdsaXMatches(.{ .x = 0, .z = z }, p - n));
        try std.testing.expect(!ecdsaXMatches(.{ .x = mul(2, zz), .z = z }, 1));
    }
    try std.testing.expect(!ecdsaXMatches(Point.infinity(), 1));
}

test "campaign tables, carries, cancellation and zero Schnorr challenge" {
    const old = @import("test_original.zig");
    for (generator_table, 0..) |entry, i| try expectSamePoint(Point{ .x = entry.x, .y = entry.y }, old.g.multiply(2 * i + 1));
    for ([_]u256{ 0, 1, n - 1, std.math.maxInt(u256) }) |scalar| {
        const digits = @import("test_residual_baseline.zig").recode(scalar);
        var value: i512 = 0;
        for (digits.values, 0..) |digit, bit| value += @as(i512, digit) << @as(u9, @intCast(bit));
        try std.testing.expectEqual(@as(i512, scalar), value);
        try expectSamePoint(joint(scalar, g, 0), old.g.multiply(scalar));
    }
    try expectSamePoint(schnorrPoint(n - 1, g, 0), old.g.multiply(n - 1));
    try std.testing.expectEqual(@as(u256, 0), joint(1, g, n - 1).z);
    for ([_]u256{ 1, 2, 17, n - 1 }) |scalar| {
        const affine = try joint(scalar, g, 0).affine();
        const rescaled = Point{ .x = mul(affine.x, 4), .y = mul(affine.y, 8), .z = 2 };
        const opposite = Point{ .x = affine.x, .y = sub(0, affine.y) };
        try expectSamePoint(rescaled.mixed(affine), (old.Point{ .x = affine.x, .y = affine.y }).double());
        try std.testing.expectEqual(@as(u256, 0), rescaled.mixed(opposite).z);
        try expectSamePoint(Point.infinity().mixed(affine), .{ .x = affine.x, .y = affine.y });
    }
    const key = (PublicKey{ .point = g }).compressed();
    const digest = [_]u8{255} ** 32;
    var sig: DerSignature = .{ .bytes = undefined, .len = 2 };
    sig.len += encodeInt(sig.bytes[sig.len..], n - 1);
    sig.len += encodeInt(sig.bytes[sig.len..], n - 1);
    sig.bytes[0] = 0x30;
    sig.bytes[1] = @intCast(sig.len - 2);
    try std.testing.expectEqual(try old.verifyEcdsa(&key, &digest, sig.slice()), try verifyEcdsa(&key, &digest, sig.slice()));
}

fn parallelPublicChecks(ok: *bool) void {
    @setRuntimeSafety(false);
    ok.* = false;
    const key = write(g.x);
    const zero = write(0);
    for (0..100) |_| {
        const result = addXOnlyTweak(&key, &zero) catch return;
        if (!std.mem.eql(u8, &result.output_xonly, &key) or result.parity != 0) return;
    }
    ok.* = true;
}
test "parallel public API calls use immutable tables" {
    var results: [8]bool = @splat(false);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, parallelPublicChecks, .{&results[i]});
    for (threads) |thread| thread.join();
    for (results) |ok| try std.testing.expect(ok);
}

// c is 129 bits. Three folds leave <2n, not necessarily <2^256.
fn reduceScalar(w: u512) u256 {
    @setRuntimeSafety(false);
    const mask: u512 = std.math.maxInt(u256);
    const c: u512 = (@as(u512, 1) << 256) - n;
    var r = (w & mask) + (w >> 256) * c;
    r = (r & mask) + (r >> 256) * c;
    r = (r & mask) + (r >> 256) * c;
    if (r >= n) r -= n;
    return @intCast(r);
}
fn scalar256(x: u256) u256 {
    @setRuntimeSafety(false);
    return if (x >= n) x - n else x;
}

fn squares(a: u256, comptime count: usize) u256 {
    @setRuntimeSafety(false);
    var r = a;
    for (0..count) |_| r = mul(r, r);
    return r;
}
fn sqrtPower(a: u256) u256 {
    @setRuntimeSafety(false);
    const m1 = a;
    const m2 = mul(squares(m1, 1), m1);
    const m3 = mul(squares(m2, 1), a);
    const m6 = mul(squares(m3, 3), m3);
    const m12 = mul(squares(m6, 6), m6);
    const m13 = mul(squares(m12, 1), a);
    const m26 = mul(squares(m13, 13), m13);
    const m27 = mul(squares(m26, 1), a);
    const m54 = mul(squares(m27, 27), m27);
    const m55 = mul(squares(m54, 1), a);
    const m110 = mul(squares(m55, 55), m55);
    const m111 = mul(squares(m110, 1), a);
    const m222 = mul(squares(m111, 111), m111);
    const m223 = mul(squares(m222, 1), a);
    const m4 = mul(squares(m2, 2), m2);
    const m5 = mul(squares(m4, 1), a);
    const m10 = mul(squares(m5, 5), m5);
    const m11 = mul(squares(m10, 1), a);
    const m22 = mul(squares(m11, 11), m11);
    var r: u256 = 1;
    r = m223;
    r = squares(r, 1);
    r = squares(r, 22);
    r = mul(r, m22);
    r = squares(r, 4);
    r = squares(r, 2);
    r = mul(r, m2);
    r = squares(r, 2);
    return r;
}

const g_width: usize = 16;
const p_width: usize = 4;

fn generatorMultiply(k: u256) Point {
    @setRuntimeSafety(false);
    const split = splitScalar(k);
    const a = recodeSigned(split[0], g_width);
    const b = recodeSigned(split[1], g_width);
    var result = Point.infinity();
    var length = @max(a.len, b.len);
    while (length != 0) {
        length -= 1;
        result = result.double();
        if (a.values[length] != 0) result = result.mixed(signedPoint(&generator_table, a.values[length]));
        if (b.values[length] != 0) result = result.mixed(signedPoint(&phi_generator_table, b.values[length]));
    }
    return result;
}

// With T=product(Z_i), scaling each point by T/Z_i produces affine
// coordinates on y^2=x^3+7*T^6. Prefix/suffix products need no inversion.
fn commonZTable(point: Point, comptime width: usize) struct { table: [1 << (width - 2)]Point, scale: u256 } {
    @setRuntimeSafety(false);
    const size = 1 << (width - 2);
    var table: [size]Point = undefined;
    table[0] = point;
    const step = point.double();
    for (1..size) |i| table[i] = table[i - 1].plus(step);
    var prefixes: [size]u256 = undefined;
    var scale: u256 = 1;
    for (table, 0..) |entry, i| {
        prefixes[i] = scale;
        if (entry.z != 0) scale = mul(scale, entry.z);
    }
    var suffix: u256 = 1;
    var i: usize = size;
    while (i != 0) {
        i -= 1;
        if (table[i].z == 0) continue;
        const factor = mul(prefixes[i], suffix);
        suffix = mul(suffix, table[i].z);
        const square = mul(factor, factor);
        table[i] = .{ .x = mul(table[i].x, square), .y = mul(table[i].y, mul(square, factor)) };
    }
    return .{ .table = table, .scale = scale };
}
fn scaleAffine(point: Point, square: u256, cube: u256) Point {
    @setRuntimeSafety(false);
    if (point.z == 0) return point;
    return .{ .x = mul(point.x, square), .y = mul(point.y, cube) };
}

test "common-Z table and isomorphic joint multiplication" {
    const original = @import("test_original.zig");
    var random = std.Random.DefaultPrng.init(0x5348415245445a);
    for (0..1000) |_| {
        const a = random.random().int(u256) % n;
        const b = random.random().int(u256) % n;
        const expected = original.g.multiply(a).plus(original.g.multiply(b));
        try expectSamePoint(joint(a, g, b), expected);
    }
    const table = commonZTable(g, p_width);
    for (table.table, 0..) |entry, i| {
        const actual = Point{ .x = entry.x, .y = entry.y, .z = table.scale };
        try expectSamePoint(actual, original.g.multiply(@intCast(2 * i + 1)));
    }
    try std.testing.expect(joint(0, g, 0).z == 0);
    try expectSamePoint(joint(1, g, n - 1), original.Point.infinity());
}

fn modPow(base: u256, exp: u256, modulus: u256) u256 {
    @setRuntimeSafety(false);
    var result: u256 = 1;
    var square = base % modulus;
    var bits = exp;
    while (bits != 0) {
        if (bits & 1 == 1) result = @intCast((@as(u512, result) * square) % modulus);
        square = @intCast((@as(u512, square) * square) % modulus);
        bits >>= 1;
    }
    return result;
}
fn cubeRootOfUnity(modulus: u256) u256 {
    @setRuntimeSafety(false);
    const exponent = (modulus - 1) / 3;
    var base: u256 = 2;
    while (base < 1000) : (base += 1) {
        const root = modPow(base, exponent, modulus);
        if (root != 1) return root;
    }
    unreachable;
}
fn binaryMultiply(k: u256, point: Point) Point {
    @setRuntimeSafety(false);
    var acc = Point.infinity();
    var bit: u9 = 256;
    while (bit != 0) {
        bit -= 1;
        acc = acc.double();
        if (((k >> @as(u8, @intCast(bit))) & 1) == 1) acc = acc.plus(point);
    }
    return acc;
}
fn wideAbs(v: i1024) i1024 {
    @setRuntimeSafety(false);
    return if (v < 0) -v else v;
}
fn nearestWide(value: i1024, denominator: i1024) i1024 {
    @setRuntimeSafety(false);
    var left = value;
    var right = denominator;
    if (right < 0) {
        left = -left;
        right = -right;
    }
    const quotient = @divTrunc(2 * wideAbs(left) + right, 2 * right);
    return if (left >= 0) quotient else -quotient;
}
fn dotWide(left: [2]i1024, right: [2]i1024) i1024 {
    @setRuntimeSafety(false);
    return left[0] * right[0] + left[1] * right[1];
}
fn gaussBasis(lam: u256) [2][2]i1024 {
    @setRuntimeSafety(false);
    var first: [2]i1024 = .{ n, 0 };
    var second: [2]i1024 = .{ -@as(i1024, lam), 1 };
    while (true) {
        if (dotWide(first, first) > dotWide(second, second)) {
            const swap = first;
            first = second;
            second = swap;
        }
        const quotient = nearestWide(dotWide(first, second), dotWide(first, first));
        if (quotient == 0) break;
        second = .{ second[0] - quotient * first[0], second[1] - quotient * first[1] };
    }
    if (first[0] * second[1] - second[0] * first[1] < 0) second = .{ -second[0], -second[1] };
    return .{ first, second };
}

test "derived cube roots and reduced lattice match the stored GLV constants" {
    const derived_beta = cubeRootOfUnity(p);
    var derived_lambda = cubeRootOfUnity(n);
    try std.testing.expect(derived_beta != 1 and modPow(derived_beta, 3, p) == 1);
    try std.testing.expect(derived_lambda != 1 and modPow(derived_lambda, 3, n) == 1);
    const image = try binaryMultiply(derived_lambda, g).affine();
    if (image.x != mul(derived_beta, g.x) or image.y != g.y) derived_lambda = @intCast((@as(u512, derived_lambda) * derived_lambda) % n);
    const paired = try binaryMultiply(derived_lambda, g).affine();
    try std.testing.expectEqual(mul(derived_beta, g.x), paired.x);
    try std.testing.expectEqual(g.y, paired.y);
    try std.testing.expectEqual(beta, derived_beta);
    try std.testing.expectEqual(lambda, derived_lambda);
    const basis = gaussBasis(derived_lambda);
    try std.testing.expectEqual(@as(i1024, basis_a[0]), basis[0][0]);
    try std.testing.expectEqual(@as(i1024, basis_a[1]), basis[0][1]);
    try std.testing.expectEqual(@as(i1024, basis_b[0]), basis[1][0]);
    try std.testing.expectEqual(@as(i1024, basis_b[1]), basis[1][1]);
    const det = basis[0][0] * basis[1][1] - basis[1][0] * basis[0][1];
    try std.testing.expectEqual(@as(i1024, n), det);
    for (basis) |vector| {
        const residue = vector[0] + @as(i1024, derived_lambda) * vector[1];
        try std.testing.expectEqual(@as(i1024, 0), @mod(residue, n));
        try std.testing.expect(wideAbs(vector[0]) < (@as(i1024, 1) << 129));
        try std.testing.expect(wideAbs(vector[1]) < (@as(i1024, 1) << 129));
    }
    const coordinate_bound = @divTrunc(wideAbs(basis[0][0]) + wideAbs(basis[1][0]) + 1, 2);
    try std.testing.expect(coordinate_bound < (@as(i1024, 1) << 129));
}
