from std.collections import List


comptime VALID = Int32(0)
comptime CONSENSUS_INVALID = Int32(1)
comptime MALFORMED = Int32(2)
comptime UNSUPPORTED = Int32(3)


struct U256(Copyable):
    var limbs: List[UInt32]

    def __init__(out self):
        self.limbs = List[UInt32]()
        for _ in range(8):
            self.limbs.append(UInt32(0))


struct Point(Copyable):
    var x: U256
    var y: U256
    var infinity: Bool

    def __init__(out self):
        self.x = U256()
        self.y = U256()
        self.infinity = True


struct JacobianPoint(Copyable):
    var x: U256
    var y: U256
    var z: U256
    var infinity: Bool

    def __init__(out self):
        self.x = U256()
        self.y = U256()
        self.z = U256()
        self.infinity = True


def pure_backend_label() -> String:
    return String("mojo-pure-secp256k1")


def _u256(
    l0: UInt32,
    l1: UInt32,
    l2: UInt32,
    l3: UInt32,
    l4: UInt32,
    l5: UInt32,
    l6: UInt32,
    l7: UInt32,
) -> U256:
    var out = U256()
    out.limbs[0] = l0
    out.limbs[1] = l1
    out.limbs[2] = l2
    out.limbs[3] = l3
    out.limbs[4] = l4
    out.limbs[5] = l5
    out.limbs[6] = l6
    out.limbs[7] = l7
    return out^


def _zero() -> U256:
    return U256()


def _one() -> U256:
    return _u256(UInt32(1), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0))


def _u256_from_u32(value: UInt32) -> U256:
    return _u256(value, UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0))


def _field_p() -> U256:
    return _u256(
        UInt32(0xFFFFFC2F),
        UInt32(0xFFFFFFFE),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
    )


def _scalar_n() -> U256:
    return _u256(
        UInt32(0xD0364141),
        UInt32(0xBFD25E8C),
        UInt32(0xAF48A03B),
        UInt32(0xBAAEDCE6),
        UInt32(0xFFFFFFFE),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
    )


def _field_p_minus_2() -> U256:
    return _u256(
        UInt32(0xFFFFFC2D),
        UInt32(0xFFFFFFFE),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
    )


def _field_sqrt_exp() -> U256:
    return _u256(
        UInt32(0xBFFFFF0C),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0x3FFFFFFF),
    )


def _gx() -> U256:
    return _u256(
        UInt32(0x16F81798),
        UInt32(0x59F2815B),
        UInt32(0x2DCE28D9),
        UInt32(0x029BFCDB),
        UInt32(0xCE870B07),
        UInt32(0x55A06295),
        UInt32(0xF9DCBBAC),
        UInt32(0x79BE667E),
    )


def _gy() -> U256:
    return _u256(
        UInt32(0xFB10D4B8),
        UInt32(0x9C47D08F),
        UInt32(0xA6855419),
        UInt32(0xFD17B448),
        UInt32(0x0E1108A8),
        UInt32(0x5DA4FBFC),
        UInt32(0x26A3C465),
        UInt32(0x483ADA77),
    )


def _generator() -> Point:
    var p = Point()
    p.x = _gx()
    p.y = _gy()
    p.infinity = False
    return p^


def _cmp(ref a: U256, ref b: U256) -> Int:
    for j in range(8):
        var i = 7 - j
        if a.limbs[i] > b.limbs[i]:
            return 1
        if a.limbs[i] < b.limbs[i]:
            return -1
    return 0


def _eq(ref a: U256, ref b: U256) -> Bool:
    return _cmp(a, b) == 0


def _is_zero(ref a: U256) -> Bool:
    for i in range(8):
        if a.limbs[i] != UInt32(0):
            return False
    return True


def _is_odd(ref a: U256) -> Bool:
    return (a.limbs[0] & UInt32(1)) == UInt32(1)


def _bit(ref a: U256, bit: Int) -> Bool:
    var limb = bit // 32
    var shift = bit - limb * 32
    return ((a.limbs[limb] >> UInt32(shift)) & UInt32(1)) == UInt32(1)


def _bit_length(ref a: U256) -> Int:
    for j in range(256):
        var i = 255 - j
        if _bit(a, i):
            return i + 1
    return 0


def _add_raw(ref a: U256, ref b: U256) -> U256:
    var out = U256()
    var carry = UInt64(0)
    for i in range(8):
        var total = UInt64(a.limbs[i]) + UInt64(b.limbs[i]) + carry
        out.limbs[i] = UInt32(total & UInt64(0xFFFFFFFF))
        carry = total >> UInt64(32)
    return out^


def _sub_raw(ref a: U256, ref b: U256) -> U256:
    var out = U256()
    var borrow = UInt64(0)
    for i in range(8):
        var av = UInt64(a.limbs[i])
        var bv = UInt64(b.limbs[i]) + borrow
        if av >= bv:
            out.limbs[i] = UInt32(av - bv)
            borrow = UInt64(0)
        else:
            out.limbs[i] = UInt32((UInt64(1) << UInt64(32)) + av - bv)
            borrow = UInt64(1)
    return out^


def _add_mod(ref a: U256, ref b: U256, ref modulus: U256) -> U256:
    var threshold = _sub_raw(modulus, b)
    if _cmp(a, threshold) >= 0:
        return _sub_raw(a, threshold)
    return _add_raw(a, b)


def _sub_mod(ref a: U256, ref b: U256, ref modulus: U256) -> U256:
    if _cmp(a, b) >= 0:
        return _sub_raw(a, b)
    var delta = _sub_raw(b, a)
    return _sub_raw(modulus, delta)


def _mul_mod(ref a: U256, ref b: U256, ref modulus: U256) -> U256:
    var p = _field_p()
    if _eq(modulus, p):
        return _mul_mod_field_fast(a, b)
    var result = _zero()
    var addend = a.copy()
    for i in range(256):
        if _bit(b, i):
            result = _add_mod(result, addend, modulus)
        var addend_copy = addend.copy()
        addend = _add_mod(addend, addend_copy, modulus)
    return result^


def _pow_mod(ref base: U256, ref exponent: U256, ref modulus: U256) -> U256:
    var result = _one()
    var power = base.copy()
    for i in range(256):
        if _bit(exponent, i):
            result = _mul_mod(result, power, modulus)
        var power_copy = power.copy()
        power = _mul_mod(power, power_copy, modulus)
    return result^


def _mul_mod_field_fast(ref a: U256, ref b: U256) -> U256:
    var product = List[UInt32]()
    for _ in range(18):
        product.append(UInt32(0))

    for i in range(8):
        var carry = UInt64(0)
        for j in range(8):
            var k = i + j
            var total = UInt64(product[k]) + UInt64(a.limbs[i]) * UInt64(b.limbs[j]) + carry
            product[k] = UInt32(total & UInt64(0xFFFFFFFF))
            carry = total >> UInt64(32)
        var idx = i + 8
        while carry != UInt64(0):
            var total = UInt64(product[idx]) + carry
            product[idx] = UInt32(total & UInt64(0xFFFFFFFF))
            carry = total >> UInt64(32)
            idx += 1

    return _reduce_field_product(product)


def _normalize_u64_limbs(mut limbs: List[UInt64]):
    for i in range(len(limbs) - 1):
        var carry = limbs[i] >> UInt64(32)
        limbs[i] = limbs[i] & UInt64(0xFFFFFFFF)
        limbs[i + 1] += carry


def _reduce_field_product(ref product: List[UInt32]) -> U256:
    # secp256k1 field reduction uses p = 2^256 - 2^32 - 977, so
    # every high 2^256 limb folds into one shifted limb plus 977 low limbs.
    var limbs = List[UInt64]()
    for i in range(24):
        if i < len(product):
            limbs.append(UInt64(product[i]))
        else:
            limbs.append(UInt64(0))

    for _ in range(6):
        _normalize_u64_limbs(limbs)
        var moved = False
        for k in range(8, len(limbs) - 1):
            var high = limbs[k]
            if high != UInt64(0):
                limbs[k] = UInt64(0)
                var low_index = k - 8
                limbs[low_index] += high * UInt64(977)
                limbs[low_index + 1] += high
                moved = True
        if not moved:
            break

    _normalize_u64_limbs(limbs)
    var out = U256()
    for i in range(8):
        out.limbs[i] = UInt32(limbs[i] & UInt64(0xFFFFFFFF))

    var p = _field_p()
    for _ in range(8):
        if _cmp(out, p) < 0:
            break
        out = _sub_raw(out, p)
    return out^


def _reduce_once(ref value: U256, ref modulus: U256) -> U256:
    if _cmp(value, modulus) >= 0:
        return _sub_raw(value, modulus)
    return value.copy()


def _from_be32(ref bytes: List[UInt8]) raises -> U256:
    if len(bytes) != 32:
        raise Error("invalid u256 byte length")
    var out = U256()
    for limb in range(8):
        var offset = 28 - limb * 4
        out.limbs[limb] = (
            (UInt32(bytes[offset]) << UInt32(24))
            | (UInt32(bytes[offset + 1]) << UInt32(16))
            | (UInt32(bytes[offset + 2]) << UInt32(8))
            | UInt32(bytes[offset + 3])
        )
    return out^


def _to_be32(ref value: U256) -> List[UInt8]:
    var out = List[UInt8]()
    for j in range(8):
        var limb = value.limbs[7 - j]
        out.append(UInt8((limb >> UInt32(24)) & UInt32(0xFF)))
        out.append(UInt8((limb >> UInt32(16)) & UInt32(0xFF)))
        out.append(UInt8((limb >> UInt32(8)) & UInt32(0xFF)))
        out.append(UInt8(limb & UInt32(0xFF)))
    return out^


def _fe_add(ref a: U256, ref b: U256) -> U256:
    var p = _field_p()
    return _add_mod(a, b, p)


def _fe_sub(ref a: U256, ref b: U256) -> U256:
    var p = _field_p()
    return _sub_mod(a, b, p)


def _fe_mul(ref a: U256, ref b: U256) -> U256:
    var p = _field_p()
    return _mul_mod(a, b, p)


def _fe_sqr(ref a: U256) -> U256:
    var tmp = a.copy()
    return _fe_mul(a, tmp)


def _fe_inv(ref a: U256) -> U256:
    var p = _field_p()
    var exp = _field_p_minus_2()
    return _pow_mod(a, exp, p)


def _fe_sqrt(ref a: U256) -> U256:
    var p = _field_p()
    var exp = _field_sqrt_exp()
    return _pow_mod(a, exp, p)


def _scalar_add(ref a: U256, ref b: U256) -> U256:
    var n = _scalar_n()
    return _add_mod(a, b, n)


def _point_neg(ref point: Point) -> Point:
    if point.infinity:
        return point.copy()
    var out = point.copy()
    if not _is_zero(out.y):
        var p = _field_p()
        out.y = _sub_raw(p, out.y)
    return out^


def _jacobian_from_affine(ref point: Point) -> JacobianPoint:
    var out = JacobianPoint()
    if point.infinity:
        return out^
    out.x = point.x.copy()
    out.y = point.y.copy()
    out.z = _one()
    out.infinity = False
    return out^


def _jacobian_to_affine(ref point: JacobianPoint) -> Point:
    var out = Point()
    if point.infinity:
        return out^
    var z_inv = _fe_inv(point.z)
    var z_inv2 = _fe_sqr(z_inv)
    var z_inv3 = _fe_mul(z_inv2, z_inv)
    out.x = _fe_mul(point.x, z_inv2)
    out.y = _fe_mul(point.y, z_inv3)
    out.infinity = False
    return out^


def _jacobian_double(ref point: JacobianPoint) -> JacobianPoint:
    if point.infinity or _is_zero(point.y):
        return JacobianPoint()
    var yy = _fe_sqr(point.y)
    var yyyy = _fe_sqr(yy)
    var xx = _fe_sqr(point.x)
    var x_times_yy = _fe_mul(point.x, yy)
    var x_times_yy_copy = x_times_yy.copy()
    var two_x_times_yy = _fe_add(x_times_yy, x_times_yy_copy)
    var two_x_times_yy_copy = two_x_times_yy.copy()
    var s = _fe_add(two_x_times_yy, two_x_times_yy_copy)
    var xx_copy = xx.copy()
    var two_xx = _fe_add(xx, xx_copy)
    var m = _fe_add(xx, two_xx)
    var m2 = _fe_sqr(m)
    var s_copy = s.copy()
    var two_s = _fe_add(s, s_copy)
    var x3 = _fe_sub(m2, two_s)
    var s_minus_x3 = _fe_sub(s, x3)
    var y3_part = _fe_mul(m, s_minus_x3)
    var eight_yyyy = yyyy.copy()
    for _ in range(3):
        var tmp = eight_yyyy.copy()
        eight_yyyy = _fe_add(eight_yyyy, tmp)
    var y3 = _fe_sub(y3_part, eight_yyyy)
    var yz = _fe_mul(point.y, point.z)
    var yz_copy = yz.copy()
    var z3 = _fe_add(yz, yz_copy)
    var out = JacobianPoint()
    out.x = x3^
    out.y = y3^
    out.z = z3^
    out.infinity = False
    return out^


def _jacobian_add_affine(ref point: JacobianPoint, ref affine: Point) -> JacobianPoint:
    if affine.infinity:
        return point.copy()
    if point.infinity:
        return _jacobian_from_affine(affine)

    var z1z1 = _fe_sqr(point.z)
    var u2 = _fe_mul(affine.x, z1z1)
    var z1_cubed = _fe_mul(z1z1, point.z)
    var s2 = _fe_mul(affine.y, z1_cubed)
    var h = _fe_sub(u2, point.x)
    var r = _fe_sub(s2, point.y)
    if _is_zero(h):
        if _is_zero(r):
            return _jacobian_double(point)
        return JacobianPoint()

    var hh = _fe_sqr(h)
    var hhh = _fe_mul(hh, h)
    var v = _fe_mul(point.x, hh)
    var r2 = _fe_sqr(r)
    var v_copy = v.copy()
    var two_v = _fe_add(v, v_copy)
    var x3 = _fe_sub(_fe_sub(r2, hhh), two_v)
    var v_minus_x3 = _fe_sub(v, x3)
    var y3 = _fe_sub(_fe_mul(r, v_minus_x3), _fe_mul(point.y, hhh))
    var z3 = _fe_mul(point.z, h)

    var out = JacobianPoint()
    out.x = x3^
    out.y = y3^
    out.z = z3^
    out.infinity = False
    return out^


def _scalar_mul_jacobian(ref scalar: U256, ref point: Point) -> JacobianPoint:
    var result = JacobianPoint()
    if _is_zero(scalar) or point.infinity:
        return result^
    for j in range(256):
        var bit_index = 255 - j
        if not result.infinity:
            result = _jacobian_double(result)
        if _bit(scalar, bit_index):
            result = _jacobian_add_affine(result, point)
    return result^


def _double_base_mul(ref s: U256, ref generator: Point, ref e: U256, ref pubkey: Point) -> JacobianPoint:
    var result = JacobianPoint()
    for j in range(256):
        var bit_index = 255 - j
        if not result.infinity:
            result = _jacobian_double(result)
        if _bit(s, bit_index):
            result = _jacobian_add_affine(result, generator)
        if _bit(e, bit_index):
            result = _jacobian_add_affine(result, pubkey)
    return result^


def _point_double(ref point: Point) -> Point:
    if point.infinity or _is_zero(point.y):
        return Point()
    var three = _u256_from_u32(UInt32(3))
    var two = _u256_from_u32(UInt32(2))
    var point_x_for_square = point.x.copy()
    var x2 = _fe_mul(point.x, point_x_for_square)
    var numerator = _fe_mul(three, x2)
    var denominator = _fe_mul(two, point.y)
    var slope = _fe_mul(numerator, _fe_inv(denominator))
    var slope_for_square = slope.copy()
    var slope2 = _fe_mul(slope, slope_for_square)
    var point_x_for_double = point.x.copy()
    var two_x = _fe_add(point.x, point_x_for_double)
    var x3 = _fe_sub(slope2, two_x)
    var x_delta = _fe_sub(point.x, x3)
    var y_part = _fe_mul(slope, x_delta)
    var y3 = _fe_sub(y_part, point.y)
    var out = Point()
    out.x = x3^
    out.y = y3^
    out.infinity = False
    return out^


def _point_add(ref a: Point, ref b: Point) -> Point:
    if a.infinity:
        return b.copy()
    if b.infinity:
        return a.copy()
    if _eq(a.x, b.x):
        if _eq(a.y, b.y):
            return _point_double(a)
        return Point()
    var numerator = _fe_sub(b.y, a.y)
    var denominator = _fe_sub(b.x, a.x)
    var slope = _fe_mul(numerator, _fe_inv(denominator))
    var slope_for_square = slope.copy()
    var slope2 = _fe_mul(slope, slope_for_square)
    var x3_part = _fe_sub(slope2, a.x)
    var x3 = _fe_sub(x3_part, b.x)
    var x_delta = _fe_sub(a.x, x3)
    var y_part = _fe_mul(slope, x_delta)
    var y3 = _fe_sub(y_part, a.y)
    var out = Point()
    out.x = x3^
    out.y = y3^
    out.infinity = False
    return out^


def _scalar_mul(ref scalar: U256, ref point: Point) -> Point:
    return _jacobian_to_affine(_scalar_mul_jacobian(scalar, point))


def _lift_x(ref x: U256) raises -> Point:
    var p = _field_p()
    if _cmp(x, p) >= 0:
        raise Error("x coordinate is not a field element")
    var x_for_square = x.copy()
    var x2 = _fe_mul(x, x_for_square)
    var x3 = _fe_mul(x2, x)
    var seven = _u256_from_u32(UInt32(7))
    var y2 = _fe_add(x3, seven)
    var y = _fe_sqrt(y2)
    var y_for_square = y.copy()
    var y_square = _fe_mul(y, y_for_square)
    if not _eq(y_square, y2):
        raise Error("x coordinate is not liftable")
    if _is_odd(y):
        y = _fe_sub(_zero(), y)
    var out = Point()
    out.x = x.copy()
    out.y = y^
    out.infinity = False
    return out^


def _append_bytes(mut out: List[UInt8], ref data: List[UInt8]):
    for i in range(len(data)):
        out.append(data[i])


def _rotr32(value: UInt32, bits: Int) -> UInt32:
    return (value >> UInt32(bits)) | (value << UInt32(32 - bits))


def _sha256_k(index: Int) -> UInt32:
    if index == 0: return UInt32(0x428A2F98)
    if index == 1: return UInt32(0x71374491)
    if index == 2: return UInt32(0xB5C0FBCF)
    if index == 3: return UInt32(0xE9B5DBA5)
    if index == 4: return UInt32(0x3956C25B)
    if index == 5: return UInt32(0x59F111F1)
    if index == 6: return UInt32(0x923F82A4)
    if index == 7: return UInt32(0xAB1C5ED5)
    if index == 8: return UInt32(0xD807AA98)
    if index == 9: return UInt32(0x12835B01)
    if index == 10: return UInt32(0x243185BE)
    if index == 11: return UInt32(0x550C7DC3)
    if index == 12: return UInt32(0x72BE5D74)
    if index == 13: return UInt32(0x80DEB1FE)
    if index == 14: return UInt32(0x9BDC06A7)
    if index == 15: return UInt32(0xC19BF174)
    if index == 16: return UInt32(0xE49B69C1)
    if index == 17: return UInt32(0xEFBE4786)
    if index == 18: return UInt32(0x0FC19DC6)
    if index == 19: return UInt32(0x240CA1CC)
    if index == 20: return UInt32(0x2DE92C6F)
    if index == 21: return UInt32(0x4A7484AA)
    if index == 22: return UInt32(0x5CB0A9DC)
    if index == 23: return UInt32(0x76F988DA)
    if index == 24: return UInt32(0x983E5152)
    if index == 25: return UInt32(0xA831C66D)
    if index == 26: return UInt32(0xB00327C8)
    if index == 27: return UInt32(0xBF597FC7)
    if index == 28: return UInt32(0xC6E00BF3)
    if index == 29: return UInt32(0xD5A79147)
    if index == 30: return UInt32(0x06CA6351)
    if index == 31: return UInt32(0x14292967)
    if index == 32: return UInt32(0x27B70A85)
    if index == 33: return UInt32(0x2E1B2138)
    if index == 34: return UInt32(0x4D2C6DFC)
    if index == 35: return UInt32(0x53380D13)
    if index == 36: return UInt32(0x650A7354)
    if index == 37: return UInt32(0x766A0ABB)
    if index == 38: return UInt32(0x81C2C92E)
    if index == 39: return UInt32(0x92722C85)
    if index == 40: return UInt32(0xA2BFE8A1)
    if index == 41: return UInt32(0xA81A664B)
    if index == 42: return UInt32(0xC24B8B70)
    if index == 43: return UInt32(0xC76C51A3)
    if index == 44: return UInt32(0xD192E819)
    if index == 45: return UInt32(0xD6990624)
    if index == 46: return UInt32(0xF40E3585)
    if index == 47: return UInt32(0x106AA070)
    if index == 48: return UInt32(0x19A4C116)
    if index == 49: return UInt32(0x1E376C08)
    if index == 50: return UInt32(0x2748774C)
    if index == 51: return UInt32(0x34B0BCB5)
    if index == 52: return UInt32(0x391C0CB3)
    if index == 53: return UInt32(0x4ED8AA4A)
    if index == 54: return UInt32(0x5B9CCA4F)
    if index == 55: return UInt32(0x682E6FF3)
    if index == 56: return UInt32(0x748F82EE)
    if index == 57: return UInt32(0x78A5636F)
    if index == 58: return UInt32(0x84C87814)
    if index == 59: return UInt32(0x8CC70208)
    if index == 60: return UInt32(0x90BEFFFA)
    if index == 61: return UInt32(0xA4506CEB)
    if index == 62: return UInt32(0xBEF9A3F7)
    return UInt32(0xC67178F2)


def _sha256(ref payload: List[UInt8]) -> List[UInt8]:
    var data = List[UInt8]()
    _append_bytes(data, payload)
    var bit_len = UInt64(len(payload)) * UInt64(8)
    data.append(UInt8(0x80))
    while len(data) % 64 != 56:
        data.append(UInt8(0))
    for i in range(8):
        data.append(UInt8((bit_len >> UInt64((7 - i) * 8)) & UInt64(0xFF)))

    var h0 = UInt32(0x6A09E667)
    var h1 = UInt32(0xBB67AE85)
    var h2 = UInt32(0x3C6EF372)
    var h3 = UInt32(0xA54FF53A)
    var h4 = UInt32(0x510E527F)
    var h5 = UInt32(0x9B05688C)
    var h6 = UInt32(0x1F83D9AB)
    var h7 = UInt32(0x5BE0CD19)

    for chunk_start in range(0, len(data), 64):
        var w = List[UInt32]()
        for i in range(16):
            var offset = chunk_start + i * 4
            var word = (UInt32(data[offset]) << UInt32(24)) | (UInt32(data[offset + 1]) << UInt32(16))
            word |= (UInt32(data[offset + 2]) << UInt32(8)) | UInt32(data[offset + 3])
            w.append(word)
        for i in range(16, 64):
            var s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >> UInt32(3))
            var s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> UInt32(10))
            w.append(w[i - 16] + s0 + w[i - 7] + s1)

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7
        for i in range(64):
            var s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)
            var ch = (e & f) ^ ((~e) & g)
            var temp1 = h + s1 + ch + _sha256_k(i) + w[i]
            var s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = s0 + maj
            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
        h5 += f
        h6 += g
        h7 += h

    var out = List[UInt8]()
    for word in [h0, h1, h2, h3, h4, h5, h6, h7]:
        out.append(UInt8((word >> UInt32(24)) & UInt32(0xFF)))
        out.append(UInt8((word >> UInt32(16)) & UInt32(0xFF)))
        out.append(UInt8((word >> UInt32(8)) & UInt32(0xFF)))
        out.append(UInt8(word & UInt32(0xFF)))
    return out^


def _ascii_bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(text.byte_length()):
        out.append(UInt8(ord(text[byte=i])))
    return out^


def _tagged_hash(tag: String, ref payload: List[UInt8]) -> List[UInt8]:
    var tag_bytes = _ascii_bytes(tag)
    var tag_digest = _sha256(tag_bytes)
    var data = List[UInt8]()
    _append_bytes(data, tag_digest)
    _append_bytes(data, tag_digest)
    _append_bytes(data, payload)
    return _sha256(data)


def _schnorr_challenge(ref rx: List[UInt8], ref px: List[UInt8], ref msg: List[UInt8]) raises -> U256:
    var payload = List[UInt8]()
    _append_bytes(payload, rx)
    _append_bytes(payload, px)
    _append_bytes(payload, msg)
    var digest = _tagged_hash(String("BIP0340/challenge"), payload)
    var e = _from_be32(digest)
    var n = _scalar_n()
    return _reduce_once(e, n)


def pure_verify_ecdsa_der_bytes(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    _ = len(pubkey)
    _ = len(der)
    _ = len(digest)
    return UNSUPPORTED


def pure_verify_schnorr_bytes(
    ref xonly_pubkey: List[UInt8],
    ref signature: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    if len(xonly_pubkey) != 32 or len(signature) != 64:
        return MALFORMED
    var p = _field_p()
    var n = _scalar_n()
    var px = _from_be32(xonly_pubkey)
    if _cmp(px, p) >= 0:
        return MALFORMED
    var pubkey = Point()
    try:
        pubkey = _lift_x(px)
    except:
        return MALFORMED
    var rx_bytes = List[UInt8]()
    for i in range(32):
        rx_bytes.append(signature[i])
    var sx_bytes = List[UInt8]()
    for i in range(32):
        sx_bytes.append(signature[32 + i])
    var rx = _from_be32(rx_bytes)
    if _cmp(rx, p) >= 0:
        return CONSENSUS_INVALID
    var s = _from_be32(sx_bytes)
    if _is_zero(s) or _cmp(s, n) >= 0:
        return CONSENSUS_INVALID
    var e = _schnorr_challenge(rx_bytes, xonly_pubkey, digest)
    var neg_e = _sub_mod(_zero(), e, n)
    var r_j = _double_base_mul(s, _generator(), neg_e, pubkey)
    var r = _jacobian_to_affine(r_j)
    if r.infinity:
        return CONSENSUS_INVALID
    if _is_odd(r.y):
        return CONSENSUS_INVALID
    if not _eq(r.x, rx):
        return CONSENSUS_INVALID
    return VALID


def pure_verify_taproot_tweak_precomputed(
    ref internal_xonly: List[UInt8],
    ref tweak: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
) raises -> Int32:
    if len(internal_xonly) != 32 or len(tweak) != 32 or len(expected_xonly) != 32:
        return MALFORMED
    if expected_parity != 0 and expected_parity != 1:
        return MALFORMED
    var p = _field_p()
    var n = _scalar_n()
    var ix = _from_be32(internal_xonly)
    if _cmp(ix, p) >= 0:
        return MALFORMED
    var internal = Point()
    try:
        internal = _lift_x(ix)
    except:
        return MALFORMED
    var tweak_scalar = _from_be32(tweak)
    if _cmp(tweak_scalar, n) >= 0:
        return MALFORMED
    var output = internal.copy()
    if not _is_zero(tweak_scalar):
        var tweaked = _scalar_mul_jacobian(tweak_scalar, _generator())
        tweaked = _jacobian_add_affine(tweaked, internal)
        output = _jacobian_to_affine(tweaked)
    if output.infinity:
        return MALFORMED
    var expected = _from_be32(expected_xonly)
    var output_parity = 0
    if _is_odd(output.y):
        output_parity = 1
    if _eq(output.x, expected) and output_parity == expected_parity:
        return VALID
    return CONSENSUS_INVALID


def pure_test_u256_add_mod(ref a: List[UInt8], ref b: List[UInt8], ref modulus: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var mv = _from_be32(modulus)
    return _to_be32(_add_mod(_reduce_once(av, mv), _reduce_once(bv, mv), mv))


def pure_test_u256_sub_mod(ref a: List[UInt8], ref b: List[UInt8], ref modulus: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var mv = _from_be32(modulus)
    return _to_be32(_sub_mod(_reduce_once(av, mv), _reduce_once(bv, mv), mv))


def pure_test_u256_mul_mod(ref a: List[UInt8], ref b: List[UInt8], ref modulus: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var mv = _from_be32(modulus)
    return _to_be32(_mul_mod(_reduce_once(av, mv), _reduce_once(bv, mv), mv))


def pure_test_u256_inv_mod(ref a: List[UInt8], ref modulus: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var mv = _from_be32(modulus)
    var exp = _sub_raw(mv, _u256_from_u32(UInt32(2)))
    return _to_be32(_pow_mod(_reduce_once(av, mv), exp, mv))


def pure_test_scalar_mul_g_x(ref scalar: List[UInt8]) raises -> List[UInt8]:
    var sv = _from_be32(scalar)
    var point = _scalar_mul(sv, _generator())
    if point.infinity:
        raise Error("scalar multiply returned infinity")
    return _to_be32(point.x)


def pure_test_scalar_mul_g_y(ref scalar: List[UInt8]) raises -> List[UInt8]:
    var sv = _from_be32(scalar)
    var point = _scalar_mul(sv, _generator())
    if point.infinity:
        raise Error("scalar multiply returned infinity")
    return _to_be32(point.y)


def pure_test_scalar_mul_g_is_infinity(ref scalar: List[UInt8]) raises -> Bool:
    var sv = _from_be32(scalar)
    return _scalar_mul_jacobian(sv, _generator()).infinity


def pure_test_schnorr_challenge(ref rx: List[UInt8], ref pubkey: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    return _to_be32(_schnorr_challenge(rx, pubkey, digest))
