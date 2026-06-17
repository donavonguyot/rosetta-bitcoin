from std.collections import InlineArray, List


comptime VALID = Int32(0)
comptime CONSENSUS_INVALID = Int32(1)
comptime MALFORMED = Int32(2)
comptime UNSUPPORTED = Int32(3)
comptime ECDSA_PRODUCT_REFERENCE = Int(0)
comptime ECDSA_PRODUCT_WNAF = Int(1)
comptime ECDSA_PRODUCT_GLV = Int(2)
comptime ECDSA_PRODUCT_FE52_WNAF = Int(3)
comptime FE52_SIMD_LANES = Int(4)


struct U256(Copyable):
    var limbs: InlineArray[UInt64, 4]

    def __init__(out self):
        self.limbs = InlineArray[UInt64, 4](fill=UInt64(0))


struct Fe52(Copyable):
    var limbs: InlineArray[UInt64, 5]
    var magnitude: Int
    var normalized: Bool

    def __init__(out self):
        self.limbs = InlineArray[UInt64, 5](fill=UInt64(0))
        self.magnitude = 0
        self.normalized = True


struct Fe52Point(Copyable):
    var x: Fe52
    var y: Fe52
    var infinity: Bool

    def __init__(out self):
        self.x = Fe52()
        self.y = Fe52()
        self.infinity = True


struct Fe52Jacobian(Copyable):
    var x: Fe52
    var y: Fe52
    var z: Fe52
    var infinity: Bool

    def __init__(out self):
        self.x = Fe52()
        self.y = Fe52()
        self.z = Fe52()
        self.infinity = True


struct Fe52x4(Copyable):
    var limbs: InlineArray[SIMD[DType.uint64, 4], 5]
    var magnitude: Int
    var normalized: Bool

    def __init__(out self):
        self.limbs = InlineArray[SIMD[DType.uint64, 4], 5](fill=SIMD[DType.uint64, 4](UInt64(0)))
        self.magnitude = 0
        self.normalized = True


struct Fe52x4Point(Copyable):
    var x: Fe52x4
    var y: Fe52x4
    var infinity: Bool

    def __init__(out self):
        self.x = Fe52x4()
        self.y = Fe52x4()
        self.infinity = True


struct Fe52x4Jacobian(Copyable):
    var x: Fe52x4
    var y: Fe52x4
    var z: Fe52x4
    var infinity: Bool

    def __init__(out self):
        self.x = Fe52x4()
        self.y = Fe52x4()
        self.z = Fe52x4()
        self.infinity = True


struct Fe52x4PowBlocks(Copyable):
    var x2: Fe52x4
    var x22: Fe52x4
    var x223: Fe52x4

    def __init__(out self):
        self.x2 = Fe52x4()
        self.x22 = Fe52x4()
        self.x223 = Fe52x4()


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


struct EcdsaSignature(Copyable):
    var r: U256
    var s: U256

    def __init__(out self):
        self.r = U256()
        self.s = U256()


struct FieldPowBlocks(Copyable):
    var x2: U256
    var x22: U256
    var x223: U256

    def __init__(out self):
        self.x2 = U256()
        self.x22 = U256()
        self.x223 = U256()


struct Fe52PowBlocks(Copyable):
    var x2: Fe52
    var x22: Fe52
    var x223: Fe52

    def __init__(out self):
        self.x2 = Fe52()
        self.x22 = Fe52()
        self.x223 = Fe52()


struct EndoSplit(Copyable):
    var s1: U256
    var p1: Point
    var s2: U256
    var p2: Point
    var s1_negated: Bool
    var s2_negated: Bool

    def __init__(out self):
        self.s1 = U256()
        self.p1 = Point()
        self.s2 = U256()
        self.p2 = Point()
        self.s1_negated = False
        self.s2_negated = False


struct Fe52GlvLoopStats(Copyable):
    var g_wnaf_len: Int
    var p_wnaf_len: Int
    var g_split_1_wnaf_len: Int
    var g_split_2_wnaf_len: Int
    var p_split_1_wnaf_len: Int
    var p_split_2_wnaf_len: Int
    var plain_max_len: Int
    var old_glv_max_len: Int
    var glv_max_len: Int
    var g_nonzero_digits: Int
    var p_nonzero_digits: Int
    var g_split_1_nonzero_digits: Int
    var g_split_2_nonzero_digits: Int
    var p_split_1_nonzero_digits: Int
    var p_split_2_nonzero_digits: Int

    def __init__(out self):
        self.g_wnaf_len = 0
        self.p_wnaf_len = 0
        self.g_split_1_wnaf_len = 0
        self.g_split_2_wnaf_len = 0
        self.p_split_1_wnaf_len = 0
        self.p_split_2_wnaf_len = 0
        self.plain_max_len = 0
        self.old_glv_max_len = 0
        self.glv_max_len = 0
        self.g_nonzero_digits = 0
        self.p_nonzero_digits = 0
        self.g_split_1_nonzero_digits = 0
        self.g_split_2_nonzero_digits = 0
        self.p_split_1_nonzero_digits = 0
        self.p_split_2_nonzero_digits = 0


struct Fe52GlvSetupStats(Copyable):
    var generator_table_builds: Int
    var beta_table_builds: Int
    var copied_tables: Int
    var negated_tables: Int
    var variable_point_table_builds: Int

    def __init__(out self):
        self.generator_table_builds = 0
        self.beta_table_builds = 0
        self.copied_tables = 0
        self.negated_tables = 0
        self.variable_point_table_builds = 0


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
    out.limbs[0] = UInt64(l0) | (UInt64(l1) << UInt64(32))
    out.limbs[1] = UInt64(l2) | (UInt64(l3) << UInt64(32))
    out.limbs[2] = UInt64(l4) | (UInt64(l5) << UInt64(32))
    out.limbs[3] = UInt64(l6) | (UInt64(l7) << UInt64(32))
    return out^


def _low64(value: UInt128) -> UInt64:
    return UInt64(value & UInt128(0xFFFFFFFFFFFFFFFF))


def _fe52_mask() -> UInt64:
    return UInt64(0xFFFFFFFFFFFFF)


def _fe52_r() -> UInt64:
    return UInt64(0x1000003D10)


def _fe52_zero() -> Fe52:
    return Fe52()


def _fe52_one() -> Fe52:
    return _fe52_from_u256(_one())


def _fe52_p_limb(index: Int) -> UInt64:
    if index == 0:
        return UInt64(0xFFFFEFFFFFC2F)
    if index == 4:
        return UInt64(0xFFFFFFFFFFFF)
    return UInt64(0xFFFFFFFFFFFFF)


def _fe52_from_u256(ref value: U256) -> Fe52:
    var out = Fe52()
    out.limbs[0] = value.limbs[0] & _fe52_mask()
    out.limbs[1] = ((value.limbs[0] >> UInt64(52)) | (value.limbs[1] << UInt64(12))) & _fe52_mask()
    out.limbs[2] = ((value.limbs[1] >> UInt64(40)) | (value.limbs[2] << UInt64(24))) & _fe52_mask()
    out.limbs[3] = ((value.limbs[2] >> UInt64(28)) | (value.limbs[3] << UInt64(36))) & _fe52_mask()
    out.limbs[4] = (value.limbs[3] >> UInt64(16)) & _fe52_mask()
    out.magnitude = 1
    out.normalized = True
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


def _scalar_half_n() -> U256:
    return _u256(
        UInt32(0x681B20A0),
        UInt32(0x5FE92F46),
        UInt32(0x57A4501D),
        UInt32(0x5D576E73),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0x7FFFFFFF),
    )


def _lambda() -> U256:
    return _u256(
        UInt32(0x1B23BD72),
        UInt32(0xDF02967C),
        UInt32(0x20816678),
        UInt32(0x122E22EA),
        UInt32(0x8812645A),
        UInt32(0xA5261C02),
        UInt32(0xC05C30E0),
        UInt32(0x5363AD4C),
    )


def _minus_b1() -> U256:
    return _u256(
        UInt32(0x0ABFE4C3),
        UInt32(0x6F547FA9),
        UInt32(0x010E8828),
        UInt32(0xE4437ED6),
        UInt32(0x00000000),
        UInt32(0x00000000),
        UInt32(0x00000000),
        UInt32(0x00000000),
    )


def _minus_b2() -> U256:
    return _u256(
        UInt32(0x3DB1562C),
        UInt32(0xD765CDA8),
        UInt32(0x0774346D),
        UInt32(0x8A280AC5),
        UInt32(0xFFFFFFFE),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
        UInt32(0xFFFFFFFF),
    )


def _glv_g1() -> U256:
    return _u256(
        UInt32(0x45DBB031),
        UInt32(0xE893209A),
        UInt32(0x71E8CA7F),
        UInt32(0x3DAA8A14),
        UInt32(0x9284EB15),
        UInt32(0xE86C90E4),
        UInt32(0xA7D46BCD),
        UInt32(0x3086D221),
    )


def _glv_g2() -> U256:
    return _u256(
        UInt32(0x8AC47F71),
        UInt32(0x1571B4AE),
        UInt32(0x9DF506C6),
        UInt32(0x221208AC),
        UInt32(0x0ABFE4C4),
        UInt32(0x6F547FA9),
        UInt32(0x010E8828),
        UInt32(0xE4437ED6),
    )


def _beta() -> U256:
    return _u256(
        UInt32(0x719501EE),
        UInt32(0xC1396C28),
        UInt32(0x12F58995),
        UInt32(0x9CF04975),
        UInt32(0xAC3434E9),
        UInt32(0x6E64479E),
        UInt32(0x657C0710),
        UInt32(0x7AE96A2B),
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


def _generator_odd_multiple(index: Int) raises -> Point:
    var out = Point()
    out.infinity = False
    if index == 0:
        out.x = _u256(UInt32(0x16F81798), UInt32(0x59F2815B), UInt32(0x2DCE28D9), UInt32(0x029BFCDB), UInt32(0xCE870B07), UInt32(0x55A06295), UInt32(0xF9DCBBAC), UInt32(0x79BE667E))
        out.y = _u256(UInt32(0xFB10D4B8), UInt32(0x9C47D08F), UInt32(0xA6855419), UInt32(0xFD17B448), UInt32(0x0E1108A8), UInt32(0x5DA4FBFC), UInt32(0x26A3C465), UInt32(0x483ADA77))
        return out^
    if index == 1:
        out.x = _u256(UInt32(0xBCE036F9), UInt32(0x8601F113), UInt32(0x836F99B0), UInt32(0xB531C845), UInt32(0xF89D5229), UInt32(0x49344F85), UInt32(0x9258C310), UInt32(0xF9308A01))
        out.y = _u256(UInt32(0x84B8E672), UInt32(0x6CB9FD75), UInt32(0x34C2231B), UInt32(0x6500A999), UInt32(0x2A37F356), UInt32(0x0FE337E6), UInt32(0x632DE814), UInt32(0x388F7B0F))
        return out^
    if index == 2:
        out.x = _u256(UInt32(0xB240EFE4), UInt32(0xCBA8D569), UInt32(0xDC619AB7), UInt32(0xE88B84BD), UInt32(0x0A5C5128), UInt32(0x55B4A725), UInt32(0x1A072093), UInt32(0x2F8BDE4D))
        out.y = _u256(UInt32(0xA6AC62D6), UInt32(0xDCA87D3A), UInt32(0xAB0D6840), UInt32(0xF788271B), UInt32(0xA6C9C426), UInt32(0xD4DBA9DD), UInt32(0x36E5E3D6), UInt32(0xD8AC2226))
        return out^
    if index == 3:
        out.x = _u256(UInt32(0xCAC4F9BC), UInt32(0xE92BDDED), UInt32(0x0330E39C), UInt32(0x3D419B7E), UInt32(0xF2EA7A0E), UInt32(0xA398F365), UInt32(0x6E5DB4EA), UInt32(0x5CBDF064))
        out.y = _u256(UInt32(0x087264DA), UInt32(0xA5082628), UInt32(0x13FDE7B5), UInt32(0xA813D0B8), UInt32(0x861A54DB), UInt32(0xA3178D6D), UInt32(0xBA255960), UInt32(0x6AEBCA40))
        return out^
    if index == 4:
        out.x = _u256(UInt32(0xFC27CCBE), UInt32(0xC35F110D), UInt32(0x4C57E714), UInt32(0xE0979697), UInt32(0x9F559ABD), UInt32(0x09AD178A), UInt32(0xF0C7F653), UInt32(0xACD484E2))
        out.y = _u256(UInt32(0xC64F9C37), UInt32(0x05CC262A), UInt32(0x375F8E0F), UInt32(0xADD888A4), UInt32(0x763B61E9), UInt32(0x64380971), UInt32(0xB0A7D9FD), UInt32(0xCC338921))
        return out^
    if index == 5:
        out.x = _u256(UInt32(0x5DA008CB), UInt32(0xBBEC1789), UInt32(0xE5C17891), UInt32(0x5649980B), UInt32(0x70C65AAC), UInt32(0x5EF4246B), UInt32(0x58A9411E), UInt32(0x774AE7F8))
        out.y = _u256(UInt32(0xC953C61B), UInt32(0x301D74C9), UInt32(0xDFF9D6A8), UInt32(0x372DB1E2), UInt32(0xD7B7B365), UInt32(0x0243DD56), UInt32(0xEB6B5E19), UInt32(0xD984A032))
        return out^
    if index == 6:
        out.x = _u256(UInt32(0x19405AA8), UInt32(0xDEEDDF8F), UInt32(0x610E58CD), UInt32(0xB075FBC6), UInt32(0xC3748651), UInt32(0xC7D1D205), UInt32(0xD975288B), UInt32(0xF28773C2))
        out.y = _u256(UInt32(0xDB03ED81), UInt32(0x29B5CB52), UInt32(0x521FA91F), UInt32(0x3A1A06DA), UInt32(0x65CDAF47), UInt32(0x758212EB), UInt32(0x8D880A89), UInt32(0x0AB0902E))
        return out^
    if index == 7:
        out.x = _u256(UInt32(0xE27E080E), UInt32(0x44ADBCF8), UInt32(0x3C85F79E), UInt32(0x31E5946F), UInt32(0x095FF411), UInt32(0x5A465AE3), UInt32(0x7D43EA96), UInt32(0xD7924D4F))
        out.y = _u256(UInt32(0xF6A26B58), UInt32(0xC504DC9F), UInt32(0xD896D3A5), UInt32(0xEA40AF2B), UInt32(0x28CC6DEF), UInt32(0x83842EC2), UInt32(0xA86C72A6), UInt32(0x581E2872))
        return out^
    raise Error("generator odd multiple index out of range")


def _cmp(ref a: U256, ref b: U256) -> Int:
    for j in range(4):
        var i = 3 - j
        if a.limbs[i] > b.limbs[i]:
            return 1
        if a.limbs[i] < b.limbs[i]:
            return -1
    return 0


def _eq(ref a: U256, ref b: U256) -> Bool:
    return _cmp(a, b) == 0


def _is_zero(ref a: U256) -> Bool:
    for i in range(4):
        if a.limbs[i] != UInt64(0):
            return False
    return True


def _is_one_value(ref a: U256) -> Bool:
    if a.limbs[0] != UInt64(1):
        return False
    for i in range(1, 4):
        if a.limbs[i] != UInt64(0):
            return False
    return True


def _is_odd(ref a: U256) -> Bool:
    return (a.limbs[0] & UInt64(1)) == UInt64(1)


def _bit(ref a: U256, bit: Int) -> Bool:
    var limb = bit // 64
    var shift = bit - limb * 64
    return ((a.limbs[limb] >> UInt64(shift)) & UInt64(1)) == UInt64(1)


def _bit_length(ref a: U256) -> Int:
    for j in range(256):
        var i = 255 - j
        if _bit(a, i):
            return i + 1
    return 0


def _add_raw(ref a: U256, ref b: U256) -> U256:
    var out = U256()
    var carry = UInt128(0)
    for i in range(4):
        var total = UInt128(a.limbs[i]) + UInt128(b.limbs[i]) + carry
        out.limbs[i] = _low64(total)
        carry = total >> UInt128(64)
    return out^


def _sub_raw(ref a: U256, ref b: U256) -> U256:
    var out = U256()
    var borrow = UInt128(0)
    for i in range(4):
        var av = UInt128(a.limbs[i])
        var bv = UInt128(b.limbs[i]) + borrow
        if av >= bv:
            out.limbs[i] = UInt64(av - bv)
            borrow = UInt128(0)
        else:
            out.limbs[i] = UInt64((UInt128(1) << UInt128(64)) + av - bv)
            borrow = UInt128(1)
    return out^


def _shr1(ref a: U256) -> U256:
    var out = U256()
    var carry = UInt64(0)
    for j in range(4):
        var i = 3 - j
        out.limbs[i] = (a.limbs[i] >> UInt64(1)) | (carry << UInt64(63))
        carry = a.limbs[i] & UInt64(1)
    return out^


def _add_small_raw(ref a: U256, value: UInt32) -> U256:
    var out = a.copy()
    var carry = UInt128(value)
    for i in range(4):
        if carry == UInt128(0):
            break
        var total = UInt128(out.limbs[i]) + carry
        out.limbs[i] = _low64(total)
        carry = total >> UInt128(64)
    return out^


def _sub_small_raw(ref a: U256, value: UInt32) -> U256:
    var out = a.copy()
    var borrow = UInt128(value)
    for i in range(4):
        if borrow == UInt128(0):
            break
        var av = UInt128(out.limbs[i])
        if av >= borrow:
            out.limbs[i] = UInt64(av - borrow)
            borrow = UInt128(0)
        else:
            out.limbs[i] = UInt64((UInt128(1) << UInt128(64)) + av - borrow)
            borrow = UInt128(1)
    return out^


def _scalar_half(ref value: U256) -> U256:
    if not _is_odd(value):
        return _shr1(value)
    var n = _scalar_n()
    var sum = InlineArray[UInt64, 5](fill=UInt64(0))
    var carry = UInt128(0)
    for i in range(4):
        var total = UInt128(value.limbs[i]) + UInt128(n.limbs[i]) + carry
        sum[i] = _low64(total)
        carry = total >> UInt128(64)
    sum[4] = UInt64(carry)

    var out = U256()
    for i in range(4):
        out.limbs[i] = (sum[i] >> UInt64(1)) | ((sum[i + 1] & UInt64(1)) << UInt64(63))
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
    var n = _scalar_n()
    if _eq(modulus, n):
        return _mul_mod_scalar_fast(a, b)
    var result = _zero()
    var addend = a.copy()
    for i in range(256):
        if _bit(b, i):
            result = _add_mod(result, addend, modulus)
        var addend_copy = addend.copy()
        addend = _add_mod(addend, addend_copy, modulus)
    return result^


def _add_product_carry(mut product: InlineArray[UInt64, 9], index: Int, carry_in: UInt128):
    var idx = index
    var carry = carry_in
    while carry != UInt128(0) and idx < 9:
        var total = UInt128(product[idx]) + carry
        product[idx] = _low64(total)
        carry = total >> UInt128(64)
        idx += 1


def _add_product_term(mut product: InlineArray[UInt64, 9], index: Int, term: UInt128):
    _add_product_carry(product, index, term)


def _schoolbook_product_4x64(ref a: U256, ref b: U256) -> InlineArray[UInt64, 9]:
    var product = InlineArray[UInt64, 9](fill=UInt64(0))
    for i in range(4):
        var carry = UInt128(0)
        for j in range(4):
            var k = i + j
            var total = UInt128(product[k]) + UInt128(a.limbs[i]) * UInt128(b.limbs[j]) + carry
            product[k] = _low64(total)
            carry = total >> UInt128(64)
        _add_product_carry(product, i + 4, carry)
    return product^


def _schoolbook_square_4x64(ref a: U256) -> InlineArray[UInt64, 9]:
    var product = InlineArray[UInt64, 9](fill=UInt64(0))
    for i in range(4):
        _add_product_term(product, i + i, UInt128(a.limbs[i]) * UInt128(a.limbs[i]))
        for j in range(i + 1, 4):
            var term = UInt128(a.limbs[i]) * UInt128(a.limbs[j])
            _add_product_term(product, i + j, term)
            _add_product_term(product, i + j, term)
    return product^


def _normalize_scalar_limbs(mut limbs: InlineArray[UInt128, 12]):
    for i in range(11):
        var carry = limbs[i] >> UInt128(64)
        limbs[i] = limbs[i] & UInt128(0xFFFFFFFFFFFFFFFF)
        limbs[i + 1] += carry


def _scalar_fold_word(mut limbs: InlineArray[UInt128, 12], offset: Int, high: UInt128):
    if high == UInt128(0):
        return
    limbs[offset] += high * UInt128(0x402DA1732FC9BEBF)
    limbs[offset + 1] += high * UInt128(0x4551231950B75FC4)
    limbs[offset + 2] += high


def _scalar_fold_high_once(mut limbs: InlineArray[UInt128, 12]):
    _normalize_scalar_limbs(limbs)
    var high = InlineArray[UInt128, 8](fill=UInt128(0))
    for i in range(8):
        high[i] = limbs[i + 4]
        limbs[i + 4] = UInt128(0)
    for i in range(8):
        _scalar_fold_word(limbs, i, high[i])
    _normalize_scalar_limbs(limbs)


def _scalar_fold_high_until_clear(mut limbs: InlineArray[UInt128, 12]):
    for _ in range(8):
        _normalize_scalar_limbs(limbs)
        var has_high = False
        for i in range(8):
            if limbs[i + 4] != UInt128(0):
                has_high = True
        if not has_high:
            break
        var high = InlineArray[UInt128, 8](fill=UInt128(0))
        for i in range(8):
            high[i] = limbs[i + 4]
            limbs[i + 4] = UInt128(0)
        for i in range(8):
            _scalar_fold_word(limbs, i, high[i])
    _normalize_scalar_limbs(limbs)


def _reduce_scalar_product(mut product: InlineArray[UInt64, 9]) -> U256:
    var limbs = InlineArray[UInt128, 12](fill=UInt128(0))
    for i in range(9):
        limbs[i] = UInt128(product[i])

    _scalar_fold_high_once(limbs)
    _scalar_fold_high_once(limbs)
    _scalar_fold_high_once(limbs)
    _scalar_fold_high_until_clear(limbs)

    var out = U256()
    for i in range(4):
        out.limbs[i] = _low64(limbs[i])
    var n = _scalar_n()
    for _ in range(4):
        if _cmp(out, n) < 0:
            break
        out = _sub_raw(out, n)
    return out^


def _mul_mod_scalar_fast(ref a: U256, ref b: U256) -> U256:
    var product = _schoolbook_product_4x64(a, b)
    return _reduce_scalar_product(product)


def _pow_mod(ref base: U256, ref exponent: U256, ref modulus: U256) -> U256:
    var result = _one()
    var power = base.copy()
    for i in range(256):
        if _bit(exponent, i):
            result = _mul_mod(result, power, modulus)
        var power_copy = power.copy()
        power = _mul_mod(power, power_copy, modulus)
    return result^


def _pow_mod_field(ref base: U256, ref exponent: U256) -> U256:
    var result = _one()
    var power = base.copy()
    for i in range(256):
        if _bit(exponent, i):
            result = _mul_mod_field_fast(result, power)
        power = _sqr_mod_field_fast(power)
    return result^


def _fe_sqr_n(ref a: U256, count: Int) -> U256:
    var out = a.copy()
    for _ in range(count):
        out = _fe_sqr(out)
    return out^


def _fe_pow_blocks(ref a: U256) -> FieldPowBlocks:
    var out = FieldPowBlocks()
    var x2 = _fe_mul(_fe_sqr(a), a)
    var x3 = _fe_mul(_fe_sqr(x2), a)
    var x6 = _fe_mul(_fe_sqr_n(x3, 3), x3)
    var x9 = _fe_mul(_fe_sqr_n(x6, 3), x3)
    var x11 = _fe_mul(_fe_sqr_n(x9, 2), x2)
    out.x2 = x2.copy()
    out.x22 = _fe_mul(_fe_sqr_n(x11, 11), x11)
    var x44 = _fe_mul(_fe_sqr_n(out.x22, 22), out.x22)
    var x88 = _fe_mul(_fe_sqr_n(x44, 44), x44)
    var x176 = _fe_mul(_fe_sqr_n(x88, 88), x88)
    var x220 = _fe_mul(_fe_sqr_n(x176, 44), x44)
    out.x223 = _fe_mul(_fe_sqr_n(x220, 3), x3)
    return out^


def _mul_mod_field_fast(ref a: U256, ref b: U256) -> U256:
    var product = _schoolbook_product_4x64(a, b)
    return _reduce_field_product(product)


def _sqr_mod_field_fast(ref a: U256) -> U256:
    var product = _schoolbook_square_4x64(a)
    return _reduce_field_product(product)


def _normalize_field_limbs(mut limbs: InlineArray[UInt128, 6]):
    for i in range(5):
        var carry = limbs[i] >> UInt128(64)
        limbs[i] = limbs[i] & UInt128(0xFFFFFFFFFFFFFFFF)
        limbs[i + 1] += carry


def _field_fold_word(mut limbs: InlineArray[UInt128, 6], offset: Int, high: UInt128):
    if high == UInt128(0):
        return
    limbs[offset] += high * UInt128(977)
    limbs[offset] += (high & UInt128(0xFFFFFFFF)) << UInt128(32)
    limbs[offset + 1] += high >> UInt128(32)


def _field_fold_high_until_clear(mut limbs: InlineArray[UInt128, 6]):
    for _ in range(8):
        _normalize_field_limbs(limbs)
        var high4 = limbs[4]
        var high5 = limbs[5]
        if high4 == UInt128(0) and high5 == UInt128(0):
            break
        limbs[4] = UInt128(0)
        limbs[5] = UInt128(0)
        _field_fold_word(limbs, 0, high4)
        _field_fold_word(limbs, 1, high5)
    _normalize_field_limbs(limbs)


def _reduce_field_product(mut product: InlineArray[UInt64, 9]) -> U256:
    # secp256k1 field reduction uses p = 2^256 - 2^32 - 977, so
    # every high 2^256 limb folds into one shifted limb plus 977 low limbs.
    var limbs = InlineArray[UInt128, 6](fill=UInt128(0))
    for i in range(4):
        limbs[i] = UInt128(product[i])

    for i in range(5):
        _field_fold_word(limbs, i, UInt128(product[i + 4]))
    _normalize_field_limbs(limbs)

    var high4 = limbs[4]
    var high5 = limbs[5]
    limbs[4] = UInt128(0)
    limbs[5] = UInt128(0)
    _field_fold_word(limbs, 0, high4)
    _field_fold_word(limbs, 1, high5)
    _normalize_field_limbs(limbs)
    _field_fold_high_until_clear(limbs)

    var out = U256()
    for i in range(4):
        out.limbs[i] = _low64(limbs[i])

    var p = _field_p()
    for _ in range(4):
        if _cmp(out, p) < 0:
            break
        out = _sub_raw(out, p)
    return out^


def _reduce_once(ref value: U256, ref modulus: U256) -> U256:
    if _cmp(value, modulus) >= 0:
        return _sub_raw(value, modulus)
    return value.copy()


def _fe52_normalize_limbs(mut limbs: InlineArray[UInt128, 12]):
    var mask = UInt128(0xFFFFFFFFFFFFF)
    for _ in range(8):
        for i in range(11):
            var carry = limbs[i] >> UInt128(52)
            limbs[i] = limbs[i] & mask
            limbs[i + 1] += carry
        var top = limbs[4] >> UInt128(48)
        if top != UInt128(0):
            limbs[4] = limbs[4] & UInt128(0xFFFFFFFFFFFF)
            limbs[0] += top * UInt128(0x1000003D1)
        var has_high = False
        for i in range(5, 12):
            if limbs[i] != UInt128(0):
                has_high = True
        if not has_high:
            break
        for i in range(5, 12):
            var high = limbs[i]
            limbs[i] = UInt128(0)
            var offset = i - 5
            while high != UInt128(0) and offset < 12:
                var chunk = high & mask
                limbs[offset] += chunk * UInt128(0x1000003D10)
                high = high >> UInt128(52)
                offset += 1
    for i in range(11):
        var carry = limbs[i] >> UInt128(52)
        limbs[i] = limbs[i] & mask
        limbs[i + 1] += carry
    var top = limbs[4] >> UInt128(48)
    if top != UInt128(0):
        limbs[4] = limbs[4] & UInt128(0xFFFFFFFFFFFF)
        limbs[0] += top * UInt128(0x1000003D1)
        for i in range(11):
            var carry = limbs[i] >> UInt128(52)
            limbs[i] = limbs[i] & mask
            limbs[i + 1] += carry


def _fe52_limbs_ge_p(ref limbs: InlineArray[UInt64, 5]) -> Bool:
    for j in range(5):
        var i = 4 - j
        var p_limb = _fe52_p_limb(i)
        if limbs[i] > p_limb:
            return True
        if limbs[i] < p_limb:
            return False
    return True


def _fe52_sub_p_once(mut limbs: InlineArray[UInt64, 5]) -> Bool:
    if not _fe52_limbs_ge_p(limbs):
        return False
    var borrow = UInt128(0)
    var base = UInt128(1) << UInt128(52)
    for i in range(5):
        var av = UInt128(limbs[i])
        var bv = UInt128(_fe52_p_limb(i)) + borrow
        if av >= bv:
            limbs[i] = UInt64(av - bv)
            borrow = UInt128(0)
        else:
            limbs[i] = UInt64(base + av - bv)
            borrow = UInt128(1)
    return True


def _fe52_normalize(ref value: Fe52) -> Fe52:
    var work = InlineArray[UInt128, 12](fill=UInt128(0))
    for i in range(5):
        work[i] = UInt128(value.limbs[i])
    _fe52_normalize_limbs(work)

    var canonical = U256()
    canonical.limbs[0] = UInt64(work[0]) | (UInt64(work[1]) << UInt64(52))
    canonical.limbs[1] = (UInt64(work[1]) >> UInt64(12)) | (UInt64(work[2]) << UInt64(40))
    canonical.limbs[2] = (UInt64(work[2]) >> UInt64(24)) | (UInt64(work[3]) << UInt64(28))
    canonical.limbs[3] = (UInt64(work[3]) >> UInt64(36)) | (UInt64(work[4]) << UInt64(16))
    var p = _field_p()
    for _ in range(4):
        if _cmp(canonical, p) < 0:
            break
        canonical = _sub_raw(canonical, p)
    return _fe52_from_u256(canonical)


def _fe52_normalize_var(ref value: Fe52) -> Fe52:
    return _fe52_normalize(value)


def _fe52_to_u256(ref value: Fe52) -> U256:
    var normalized = _fe52_normalize(value)
    var out = U256()
    out.limbs[0] = normalized.limbs[0] | (normalized.limbs[1] << UInt64(52))
    out.limbs[1] = (normalized.limbs[1] >> UInt64(12)) | (normalized.limbs[2] << UInt64(40))
    out.limbs[2] = (normalized.limbs[2] >> UInt64(24)) | (normalized.limbs[3] << UInt64(28))
    out.limbs[3] = (normalized.limbs[3] >> UInt64(36)) | (normalized.limbs[4] << UInt64(16))
    return out^


def _fe52_add(ref a: Fe52, ref b: Fe52) -> Fe52:
    var out = Fe52()
    for i in range(5):
        out.limbs[i] = a.limbs[i] + b.limbs[i]
    out.magnitude = a.magnitude + b.magnitude
    if out.magnitude < 1:
        out.magnitude = 1
    out.normalized = False
    return out^


def _fe52_negate(ref a: Fe52) -> Fe52:
    var m = a.magnitude
    if m < 1:
        m = 1
    var factor = UInt64(2 * (m + 1))
    var out = Fe52()
    var borrow = UInt128(0)
    var base = UInt128(1) << UInt128(52)
    for i in range(5):
        var av = UInt128(_fe52_p_limb(i)) * UInt128(factor)
        var bv = UInt128(a.limbs[i]) + borrow
        if av >= bv:
            out.limbs[i] = UInt64(av - bv)
            borrow = UInt128(0)
        else:
            out.limbs[i] = UInt64(base + av - bv)
            borrow = UInt128(1)
    out.magnitude = m + 1
    out.normalized = False
    return out^


def _fe52_mul_int(ref a: Fe52, scalar: UInt32) -> Fe52:
    var out = Fe52()
    for i in range(5):
        out.limbs[i] = UInt64(UInt128(a.limbs[i]) * UInt128(scalar))
    out.magnitude = a.magnitude * Int(scalar)
    if out.magnitude < 1:
        out.magnitude = 1
    out.normalized = False
    return out^


def _fe52_mul(ref a: Fe52, ref b: Fe52) -> Fe52:
    var m = UInt128(0xFFFFFFFFFFFFF)
    var r = UInt128(0x1000003D10)
    var a0 = UInt128(a.limbs[0])
    var a1 = UInt128(a.limbs[1])
    var a2 = UInt128(a.limbs[2])
    var a3 = UInt128(a.limbs[3])
    var a4 = UInt128(a.limbs[4])
    var b0 = UInt128(b.limbs[0])
    var b1 = UInt128(b.limbs[1])
    var b2 = UInt128(b.limbs[2])
    var b3 = UInt128(b.limbs[3])
    var b4 = UInt128(b.limbs[4])

    var d = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
    var c = a4 * b4
    d += r * (c & UInt128(0xFFFFFFFFFFFFFFFF))
    c = c >> UInt128(64)
    var t3 = d & m
    d = d >> UInt128(52)

    d += a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0
    d += (r << UInt128(12)) * (c & UInt128(0xFFFFFFFFFFFFFFFF))
    var t4 = d & m
    d = d >> UInt128(52)
    var tx = t4 >> UInt128(48)
    t4 = t4 & (m >> UInt128(4))

    c = a0 * b0
    d += a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1
    var u0 = d & m
    d = d >> UInt128(52)
    u0 = (u0 << UInt128(4)) | tx
    c += u0 * (r >> UInt128(4))
    var r0 = c & m
    c = c >> UInt128(52)

    c += a0 * b1 + a1 * b0
    d += a2 * b4 + a3 * b3 + a4 * b2
    c += (d & m) * r
    d = d >> UInt128(52)
    var r1 = c & m
    c = c >> UInt128(52)

    c += a0 * b2 + a1 * b1 + a2 * b0
    d += a3 * b4 + a4 * b3
    c += r * (d & UInt128(0xFFFFFFFFFFFFFFFF))
    d = d >> UInt128(64)
    var r2 = c & m
    c = c >> UInt128(52)

    c += (r << UInt128(12)) * (d & UInt128(0xFFFFFFFFFFFFFFFF)) + t3
    var r3 = c & m
    c = c >> UInt128(52)
    var r4 = c + t4

    var out = Fe52()
    out.limbs[0] = UInt64(r0)
    out.limbs[1] = UInt64(r1)
    out.limbs[2] = UInt64(r2)
    out.limbs[3] = UInt64(r3)
    out.limbs[4] = UInt64(r4)
    out.magnitude = 1
    out.normalized = False
    return out^


def _fe52_sqr(ref a: Fe52) -> Fe52:
    var m = UInt128(0xFFFFFFFFFFFFF)
    var r = UInt128(0x1000003D10)
    var a0 = UInt128(a.limbs[0])
    var a1 = UInt128(a.limbs[1])
    var a2 = UInt128(a.limbs[2])
    var a3 = UInt128(a.limbs[3])
    var a4 = UInt128(a.limbs[4])

    var d = (a0 * UInt128(2)) * a3 + (a1 * UInt128(2)) * a2
    var c = a4 * a4
    d += r * (c & UInt128(0xFFFFFFFFFFFFFFFF))
    c = c >> UInt128(64)
    var t3 = d & m
    d = d >> UInt128(52)

    a4 = a4 * UInt128(2)
    d += a0 * a4 + (a1 * UInt128(2)) * a3 + a2 * a2
    d += (r << UInt128(12)) * (c & UInt128(0xFFFFFFFFFFFFFFFF))
    var t4 = d & m
    d = d >> UInt128(52)
    var tx = t4 >> UInt128(48)
    t4 = t4 & (m >> UInt128(4))

    c = a0 * a0
    d += a1 * a4 + (a2 * UInt128(2)) * a3
    var u0 = d & m
    d = d >> UInt128(52)
    u0 = (u0 << UInt128(4)) | tx
    c += u0 * (r >> UInt128(4))
    var r0 = c & m
    c = c >> UInt128(52)

    a0 = a0 * UInt128(2)
    c += a0 * a1
    d += a2 * a4 + a3 * a3
    c += (d & m) * r
    d = d >> UInt128(52)
    var r1 = c & m
    c = c >> UInt128(52)

    c += a0 * a2 + a1 * a1
    d += a3 * a4
    c += r * (d & UInt128(0xFFFFFFFFFFFFFFFF))
    d = d >> UInt128(64)
    var r2 = c & m
    c = c >> UInt128(52)

    c += (r << UInt128(12)) * (d & UInt128(0xFFFFFFFFFFFFFFFF)) + t3
    var r3 = c & m
    c = c >> UInt128(52)
    var r4 = c + t4

    var out = Fe52()
    out.limbs[0] = UInt64(r0)
    out.limbs[1] = UInt64(r1)
    out.limbs[2] = UInt64(r2)
    out.limbs[3] = UInt64(r3)
    out.limbs[4] = UInt64(r4)
    out.magnitude = 1
    out.normalized = False
    return out^


def _fe52_equal(ref a: Fe52, ref b: Fe52) -> Bool:
    var an = _fe52_normalize(a)
    var bn = _fe52_normalize(b)
    for i in range(5):
        if an.limbs[i] != bn.limbs[i]:
            return False
    return True


def _fe52_is_zero(ref a: Fe52) -> Bool:
    var normalized = _fe52_normalize(a)
    for i in range(5):
        if normalized.limbs[i] != UInt64(0):
            return False
    return True


def _fe52_half(ref a: Fe52) -> Fe52:
    var t0 = a.limbs[0]
    var t1 = a.limbs[1]
    var t2 = a.limbs[2]
    var t3 = a.limbs[3]
    var t4 = a.limbs[4]
    var mask = UInt64(0)
    if (t0 & UInt64(1)) == UInt64(1):
        mask = UInt64(0xFFFFFFFFFFFFF)
    t0 += UInt64(0xFFFFEFFFFFC2F) & mask
    t1 += mask
    t2 += mask
    t3 += mask
    t4 += mask >> UInt64(4)

    var out = Fe52()
    out.limbs[0] = (t0 >> UInt64(1)) + ((t1 & UInt64(1)) << UInt64(51))
    out.limbs[1] = (t1 >> UInt64(1)) + ((t2 & UInt64(1)) << UInt64(51))
    out.limbs[2] = (t2 >> UInt64(1)) + ((t3 & UInt64(1)) << UInt64(51))
    out.limbs[3] = (t3 >> UInt64(1)) + ((t4 & UInt64(1)) << UInt64(51))
    out.limbs[4] = t4 >> UInt64(1)
    out.magnitude = (a.magnitude >> 1) + 1
    out.normalized = False
    return out^


def _fe52_normalizes_to_zero_var(ref a: Fe52) -> Bool:
    var m = UInt64(0xFFFFFFFFFFFFF)
    var t0 = a.limbs[0]
    var t4 = a.limbs[4]
    var x = t4 >> UInt64(48)
    t0 += x * UInt64(0x1000003D1)
    var z0 = t0 & m
    var z1 = z0 ^ UInt64(0x1000003D0)
    if z0 != UInt64(0) and z1 != m:
        return False

    var t1 = a.limbs[1]
    var t2 = a.limbs[2]
    var t3 = a.limbs[3]
    t4 = t4 & UInt64(0x0FFFFFFFFFFFF)
    t1 += t0 >> UInt64(52)
    t2 += t1 >> UInt64(52)
    t1 = t1 & m
    z0 = z0 | t1
    z1 = z1 & t1
    t3 += t2 >> UInt64(52)
    t2 = t2 & m
    z0 = z0 | t2
    z1 = z1 & t2
    t4 += t3 >> UInt64(52)
    t3 = t3 & m
    z0 = z0 | t3
    z1 = z1 & t3
    z0 = z0 | t4
    z1 = z1 & (t4 ^ UInt64(0xF000000000000))
    return z0 == UInt64(0) or z1 == m


def _fe52_sqr_n(ref a: Fe52, count: Int) -> Fe52:
    var out = a.copy()
    for _ in range(count):
        out = _fe52_sqr(out)
    return out^


def _fe52_pow_blocks(ref a: Fe52) -> Fe52PowBlocks:
    var out = Fe52PowBlocks()
    var x2 = _fe52_mul(_fe52_sqr(a), a)
    var x3 = _fe52_mul(_fe52_sqr(x2), a)
    var x6 = _fe52_mul(_fe52_sqr_n(x3, 3), x3)
    var x9 = _fe52_mul(_fe52_sqr_n(x6, 3), x3)
    var x11 = _fe52_mul(_fe52_sqr_n(x9, 2), x2)
    out.x2 = x2.copy()
    out.x22 = _fe52_mul(_fe52_sqr_n(x11, 11), x11)
    var x44 = _fe52_mul(_fe52_sqr_n(out.x22, 22), out.x22)
    var x88 = _fe52_mul(_fe52_sqr_n(x44, 44), x44)
    var x176 = _fe52_mul(_fe52_sqr_n(x88, 88), x88)
    var x220 = _fe52_mul(_fe52_sqr_n(x176, 44), x44)
    out.x223 = _fe52_mul(_fe52_sqr_n(x220, 3), x3)
    return out^


def _fe52_inv(ref a: Fe52) -> Fe52:
    var blocks = _fe52_pow_blocks(a)
    var out = _fe52_sqr_n(blocks.x223, 23)
    out = _fe52_mul(out, blocks.x22)
    out = _fe52_sqr_n(out, 5)
    out = _fe52_mul(out, a)
    out = _fe52_sqr_n(out, 3)
    out = _fe52_mul(out, blocks.x2)
    out = _fe52_sqr_n(out, 2)
    return _fe52_mul(out, a)


def _fe52_sqrt(ref a: Fe52) -> Fe52:
    var blocks = _fe52_pow_blocks(a)
    var out = _fe52_sqr_n(blocks.x223, 23)
    out = _fe52_mul(out, blocks.x22)
    out = _fe52_sqr_n(out, 6)
    out = _fe52_mul(out, blocks.x2)
    return _fe52_sqr_n(out, 2)


def _u128x4(value: UInt128) -> SIMD[DType.uint128, 4]:
    return SIMD[DType.uint128, 4](value)


def _u64x4(value: UInt64) -> SIMD[DType.uint64, 4]:
    return SIMD[DType.uint64, 4](value)


def _fe52x4_from_fe52(ref value: Fe52) -> Fe52x4:
    var out = Fe52x4()
    for i in range(5):
        out.limbs[i] = _u64x4(value.limbs[i])
    out.magnitude = value.magnitude
    out.normalized = value.normalized
    return out^


def _fe52x4_lane_to_fe52(ref value: Fe52x4, lane: Int) -> Fe52:
    var out = Fe52()
    for i in range(5):
        out.limbs[i] = value.limbs[i][lane]
    out.magnitude = value.magnitude
    out.normalized = value.normalized
    return out^


def _fe52x4_one() -> Fe52x4:
    return _fe52x4_from_fe52(_fe52_one())


def _fe52x4_add(ref a: Fe52x4, ref b: Fe52x4) -> Fe52x4:
    var out = Fe52x4()
    for i in range(5):
        out.limbs[i] = a.limbs[i] + b.limbs[i]
    out.magnitude = a.magnitude + b.magnitude
    if out.magnitude < 1:
        out.magnitude = 1
    out.normalized = False
    return out^


def _fe52x4_negate(ref a: Fe52x4) -> Fe52x4:
    # K=4 diagnostic batches intentionally keep homogeneous lane control flow.
    # Mojo 1.0b1 exposes scalar Bool for this UInt128 SIMD comparison, so use
    # the already-proven scalar negate on lane 0 and splat the result.
    return _fe52x4_from_fe52(_fe52_negate(_fe52x4_lane_to_fe52(a, 0)))


def _fe52x4_mul_int(ref a: Fe52x4, scalar: UInt32) -> Fe52x4:
    var out = Fe52x4()
    var scalar_w = _u128x4(UInt128(scalar))
    for i in range(5):
        out.limbs[i] = (a.limbs[i].cast[DType.uint128]() * scalar_w).cast[DType.uint64]()
    out.magnitude = a.magnitude * Int(scalar)
    if out.magnitude < 1:
        out.magnitude = 1
    out.normalized = False
    return out^


def _fe52x4_mul(ref a: Fe52x4, ref b: Fe52x4) -> Fe52x4:
    var m = _u128x4(UInt128(0xFFFFFFFFFFFFF))
    var r = _u128x4(UInt128(0x1000003D10))
    var a0 = a.limbs[0].cast[DType.uint128]()
    var a1 = a.limbs[1].cast[DType.uint128]()
    var a2 = a.limbs[2].cast[DType.uint128]()
    var a3 = a.limbs[3].cast[DType.uint128]()
    var a4 = a.limbs[4].cast[DType.uint128]()
    var b0 = b.limbs[0].cast[DType.uint128]()
    var b1 = b.limbs[1].cast[DType.uint128]()
    var b2 = b.limbs[2].cast[DType.uint128]()
    var b3 = b.limbs[3].cast[DType.uint128]()
    var b4 = b.limbs[4].cast[DType.uint128]()

    var d = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
    var c = a4 * b4
    d += r * (c & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    c = c >> _u128x4(UInt128(64))
    var t3 = d & m
    d = d >> _u128x4(UInt128(52))

    d += a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0
    d += (r << _u128x4(UInt128(12))) * (c & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    var t4 = d & m
    d = d >> _u128x4(UInt128(52))
    var tx = t4 >> _u128x4(UInt128(48))
    t4 = t4 & (m >> _u128x4(UInt128(4)))

    c = a0 * b0
    d += a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1
    var u0 = d & m
    d = d >> _u128x4(UInt128(52))
    u0 = (u0 << _u128x4(UInt128(4))) | tx
    c += u0 * (r >> _u128x4(UInt128(4)))
    var r0 = c & m
    c = c >> _u128x4(UInt128(52))

    c += a0 * b1 + a1 * b0
    d += a2 * b4 + a3 * b3 + a4 * b2
    c += (d & m) * r
    d = d >> _u128x4(UInt128(52))
    var r1 = c & m
    c = c >> _u128x4(UInt128(52))

    c += a0 * b2 + a1 * b1 + a2 * b0
    d += a3 * b4 + a4 * b3
    c += r * (d & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    d = d >> _u128x4(UInt128(64))
    var r2 = c & m
    c = c >> _u128x4(UInt128(52))

    c += (r << _u128x4(UInt128(12))) * (d & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF))) + t3
    var r3 = c & m
    c = c >> _u128x4(UInt128(52))
    var r4 = c + t4

    var out = Fe52x4()
    out.limbs[0] = r0.cast[DType.uint64]()
    out.limbs[1] = r1.cast[DType.uint64]()
    out.limbs[2] = r2.cast[DType.uint64]()
    out.limbs[3] = r3.cast[DType.uint64]()
    out.limbs[4] = r4.cast[DType.uint64]()
    out.magnitude = 1
    out.normalized = False
    return out^


def _fe52x4_sqr(ref a: Fe52x4) -> Fe52x4:
    var m = _u128x4(UInt128(0xFFFFFFFFFFFFF))
    var r = _u128x4(UInt128(0x1000003D10))
    var a0 = a.limbs[0].cast[DType.uint128]()
    var a1 = a.limbs[1].cast[DType.uint128]()
    var a2 = a.limbs[2].cast[DType.uint128]()
    var a3 = a.limbs[3].cast[DType.uint128]()
    var a4 = a.limbs[4].cast[DType.uint128]()

    var d = (a0 * _u128x4(UInt128(2))) * a3 + (a1 * _u128x4(UInt128(2))) * a2
    var c = a4 * a4
    d += r * (c & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    c = c >> _u128x4(UInt128(64))
    var t3 = d & m
    d = d >> _u128x4(UInt128(52))

    a4 = a4 * _u128x4(UInt128(2))
    d += a0 * a4 + (a1 * _u128x4(UInt128(2))) * a3 + a2 * a2
    d += (r << _u128x4(UInt128(12))) * (c & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    var t4 = d & m
    d = d >> _u128x4(UInt128(52))
    var tx = t4 >> _u128x4(UInt128(48))
    t4 = t4 & (m >> _u128x4(UInt128(4)))

    c = a0 * a0
    d += a1 * a4 + (a2 * _u128x4(UInt128(2))) * a3
    var u0 = d & m
    d = d >> _u128x4(UInt128(52))
    u0 = (u0 << _u128x4(UInt128(4))) | tx
    c += u0 * (r >> _u128x4(UInt128(4)))
    var r0 = c & m
    c = c >> _u128x4(UInt128(52))

    a0 = a0 * _u128x4(UInt128(2))
    c += a0 * a1
    d += a2 * a4 + a3 * a3
    c += (d & m) * r
    d = d >> _u128x4(UInt128(52))
    var r1 = c & m
    c = c >> _u128x4(UInt128(52))

    c += a0 * a2 + a1 * a1
    d += a3 * a4
    c += r * (d & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF)))
    d = d >> _u128x4(UInt128(64))
    var r2 = c & m
    c = c >> _u128x4(UInt128(52))

    c += (r << _u128x4(UInt128(12))) * (d & _u128x4(UInt128(0xFFFFFFFFFFFFFFFF))) + t3
    var r3 = c & m
    c = c >> _u128x4(UInt128(52))
    var r4 = c + t4

    var out = Fe52x4()
    out.limbs[0] = r0.cast[DType.uint64]()
    out.limbs[1] = r1.cast[DType.uint64]()
    out.limbs[2] = r2.cast[DType.uint64]()
    out.limbs[3] = r3.cast[DType.uint64]()
    out.limbs[4] = r4.cast[DType.uint64]()
    out.magnitude = 1
    out.normalized = False
    return out^


def _fe52x4_sqr_n(ref a: Fe52x4, count: Int) -> Fe52x4:
    var out = a.copy()
    for _ in range(count):
        out = _fe52x4_sqr(out)
    return out^


def _fe52x4_pow_blocks(ref a: Fe52x4) -> Fe52x4PowBlocks:
    var out = Fe52x4PowBlocks()
    var x2 = _fe52x4_mul(_fe52x4_sqr(a), a)
    var x3 = _fe52x4_mul(_fe52x4_sqr(x2), a)
    var x6 = _fe52x4_mul(_fe52x4_sqr_n(x3, 3), x3)
    var x9 = _fe52x4_mul(_fe52x4_sqr_n(x6, 3), x3)
    var x11 = _fe52x4_mul(_fe52x4_sqr_n(x9, 2), x2)
    out.x2 = x2.copy()
    out.x22 = _fe52x4_mul(_fe52x4_sqr_n(x11, 11), x11)
    var x44 = _fe52x4_mul(_fe52x4_sqr_n(out.x22, 22), out.x22)
    var x88 = _fe52x4_mul(_fe52x4_sqr_n(x44, 44), x44)
    var x176 = _fe52x4_mul(_fe52x4_sqr_n(x88, 88), x88)
    var x220 = _fe52x4_mul(_fe52x4_sqr_n(x176, 44), x44)
    out.x223 = _fe52x4_mul(_fe52x4_sqr_n(x220, 3), x3)
    return out^


def _fe52x4_inv(ref a: Fe52x4) -> Fe52x4:
    var blocks = _fe52x4_pow_blocks(a)
    var out = _fe52x4_sqr_n(blocks.x223, 23)
    out = _fe52x4_mul(out, blocks.x22)
    out = _fe52x4_sqr_n(out, 5)
    out = _fe52x4_mul(out, a)
    out = _fe52x4_sqr_n(out, 3)
    out = _fe52x4_mul(out, blocks.x2)
    out = _fe52x4_sqr_n(out, 2)
    return _fe52x4_mul(out, a)


def _fe52x4_normalizes_to_zero_var(ref a: Fe52x4) -> Bool:
    return _fe52_normalizes_to_zero_var(_fe52x4_lane_to_fe52(a, 0))


def _fe52x4_jacobian_from_affine(ref point: Fe52Point) -> Fe52x4Jacobian:
    var out = Fe52x4Jacobian()
    if point.infinity:
        return out^
    out.x = _fe52x4_from_fe52(point.x)
    out.y = _fe52x4_from_fe52(point.y)
    out.z = _fe52x4_one()
    out.infinity = False
    return out^


def _fe52x4_jacobian_to_affine(ref point: Fe52x4Jacobian) -> Fe52x4Point:
    var out = Fe52x4Point()
    if point.infinity:
        return out^
    var z_inv = _fe52x4_inv(point.z)
    var z_inv2 = _fe52x4_sqr(z_inv)
    var z_inv3 = _fe52x4_mul(z_inv2, z_inv)
    out.x = _fe52x4_mul(point.x, z_inv2)
    out.y = _fe52x4_mul(point.y, z_inv3)
    out.infinity = False
    return out^


def _fe52x4_point_lane_to_fe52(ref point: Fe52x4Point, lane: Int) -> Fe52Point:
    var out = Fe52Point()
    if point.infinity:
        return out^
    out.x = _fe52x4_lane_to_fe52(point.x, lane)
    out.y = _fe52x4_lane_to_fe52(point.y, lane)
    out.infinity = False
    return out^


def _fe52x4_gej_double(ref a: Fe52x4Jacobian) -> Fe52x4Jacobian:
    var out = Fe52x4Jacobian()
    out.infinity = a.infinity
    if a.infinity:
        return out^
    if _fe52x4_normalizes_to_zero_var(a.y):
        return Fe52x4Jacobian()
    out.z = _fe52x4_mul(a.z, a.y)
    var s = _fe52x4_sqr(a.y)
    var l = _fe52x4_sqr(a.x)
    l = _fe52x4_mul_int(l, UInt32(3))
    var l_lane = _fe52_half(_fe52x4_lane_to_fe52(l, 0))
    l = _fe52x4_from_fe52(l_lane)
    var t = _fe52x4_negate(s)
    t = _fe52x4_mul(t, a.x)
    out.x = _fe52x4_sqr(l)
    out.x = _fe52x4_add(out.x, t)
    out.x = _fe52x4_add(out.x, t)
    s = _fe52x4_sqr(s)
    t = _fe52x4_add(t, out.x)
    out.y = _fe52x4_mul(t, l)
    out.y = _fe52x4_add(out.y, s)
    out.y = _fe52x4_negate(out.y)
    out.infinity = False
    return out^


def _fe52x4_gej_add_ge_var(ref a: Fe52x4Jacobian, ref b: Fe52Point) -> Fe52x4Jacobian:
    if a.infinity:
        return _fe52x4_jacobian_from_affine(b)
    if b.infinity:
        return a.copy()

    var bx = _fe52x4_from_fe52(b.x)
    var by = _fe52x4_from_fe52(b.y)
    var z12 = _fe52x4_sqr(a.z)
    var u1 = a.x.copy()
    var u2 = _fe52x4_mul(bx, z12)
    var s1 = a.y.copy()
    var s2 = _fe52x4_mul(by, z12)
    s2 = _fe52x4_mul(s2, a.z)
    var h = _fe52x4_add(_fe52x4_negate(u1), u2)
    var i = _fe52x4_add(_fe52x4_negate(s2), s1)
    if _fe52x4_normalizes_to_zero_var(h):
        if _fe52x4_normalizes_to_zero_var(i):
            return _fe52x4_gej_double(a)
        return Fe52x4Jacobian()

    var out = Fe52x4Jacobian()
    out.infinity = False
    out.z = _fe52x4_mul(a.z, h)
    var h2 = _fe52x4_negate(_fe52x4_sqr(h))
    var h3 = _fe52x4_mul(h2, h)
    var t = _fe52x4_mul(u1, h2)
    out.x = _fe52x4_sqr(i)
    out.x = _fe52x4_add(out.x, h3)
    out.x = _fe52x4_add(out.x, t)
    out.x = _fe52x4_add(out.x, t)
    t = _fe52x4_add(t, out.x)
    out.y = _fe52x4_mul(t, i)
    h3 = _fe52x4_mul(h3, s1)
    out.y = _fe52x4_add(out.y, h3)
    return out^


def _fe52x4_wnaf_table_add(mut result: Fe52x4Jacobian, ref table: List[Fe52Point], digit: Int) raises -> Fe52x4Jacobian:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = table[table_index].copy()
    if digit < 0:
        point = _fe52_point_neg(point)
    return _fe52x4_gej_add_ge_var(result, point)


def _fe52x4_wnaf_generator_add(mut result: Fe52x4Jacobian, digit: Int) raises -> Fe52x4Jacobian:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = _fe52_point_from_point(_generator_odd_multiple(table_index))
    if digit < 0:
        point = _fe52_point_neg(point)
    return _fe52x4_gej_add_ge_var(result, point)


def _fe52x4_double_base_mul_wnaf_identical(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Fe52Point) raises -> Fe52x4Jacobian:
    var width = 5
    var g_wnaf = _wnaf_recode(g_scalar, width)
    var p_wnaf = _wnaf_recode(p_scalar, width)
    var p_table = _fe52_odd_multiples_from_fe52(pubkey, 8)
    var max_len = len(g_wnaf)
    if len(p_wnaf) > max_len:
        max_len = len(p_wnaf)

    var result = Fe52x4Jacobian()
    for j in range(max_len):
        var i = max_len - 1 - j
        if not result.infinity:
            result = _fe52x4_gej_double(result)
        if i < len(g_wnaf):
            result = _fe52x4_wnaf_generator_add(result, g_wnaf[i])
        if i < len(p_wnaf):
            result = _fe52x4_wnaf_table_add(result, p_table, p_wnaf[i])
    return result^


def _fe52_point_from_point(ref point: Point) -> Fe52Point:
    var out = Fe52Point()
    if point.infinity:
        return out^
    out.x = _fe52_from_u256(point.x)
    out.y = _fe52_from_u256(point.y)
    out.infinity = False
    return out^


def _point_from_fe52_point(ref point: Fe52Point) -> Point:
    var out = Point()
    if point.infinity:
        return out^
    out.x = _fe52_to_u256(point.x)
    out.y = _fe52_to_u256(point.y)
    out.infinity = False
    return out^


def _fe52_lift_x(ref x: U256) raises -> Fe52Point:
    var p = _field_p()
    if _cmp(x, p) >= 0:
        raise Error("x coordinate is not a field element")
    var x_fe = _fe52_from_u256(x)
    var x2 = _fe52_sqr(x_fe)
    var x3 = _fe52_mul(x2, x_fe)
    var y2 = _fe52_add(x3, _fe52_from_u256(_u256_from_u32(UInt32(7))))
    var y = _fe52_sqrt(y2)
    if not _fe52_equal(_fe52_sqr(y), y2):
        raise Error("x coordinate is not liftable")
    if _is_odd(_fe52_to_u256(y)):
        y = _fe52_negate(y)
    var out = Fe52Point()
    out.x = x_fe.copy()
    out.y = y^
    out.infinity = False
    return out^


def _fe52_parse_pubkey(ref pubkey: List[UInt8]) raises -> Fe52Point:
    var p = _field_p()
    if len(pubkey) == 33 and (pubkey[0] == UInt8(0x02) or pubkey[0] == UInt8(0x03)):
        var x_bytes = List[UInt8]()
        for i in range(32):
            x_bytes.append(pubkey[i + 1])
        var point = _fe52_lift_x(_from_be32(x_bytes))
        if pubkey[0] == UInt8(0x03):
            point.y = _fe52_negate(point.y)
        return point^
    if len(pubkey) == 65 and pubkey[0] == UInt8(0x04):
        var x_bytes = List[UInt8]()
        var y_bytes = List[UInt8]()
        for i in range(32):
            x_bytes.append(pubkey[i + 1])
            y_bytes.append(pubkey[i + 33])
        var x = _from_be32(x_bytes)
        var y = _from_be32(y_bytes)
        if _cmp(x, p) >= 0 or _cmp(y, p) >= 0:
            raise Error("pubkey coordinate out of range")
        var x_fe = _fe52_from_u256(x)
        var y_fe = _fe52_from_u256(y)
        var x2 = _fe52_sqr(x_fe)
        var x3 = _fe52_mul(x2, x_fe)
        var expected_y2 = _fe52_add(x3, _fe52_from_u256(_u256_from_u32(UInt32(7))))
        if not _fe52_equal(_fe52_sqr(y_fe), expected_y2):
            raise Error("pubkey is not on secp256k1")
        var point = Fe52Point()
        point.x = x_fe^
        point.y = y_fe^
        point.infinity = False
        return point^
    raise Error("invalid pubkey length")


def _fe52_jacobian_from_affine(ref point: Fe52Point) -> Fe52Jacobian:
    var out = Fe52Jacobian()
    if point.infinity:
        return out^
    out.x = point.x.copy()
    out.y = point.y.copy()
    out.z = _fe52_one()
    out.infinity = False
    return out^


def _fe52_jacobian_to_affine(ref point: Fe52Jacobian) -> Fe52Point:
    var out = Fe52Point()
    if point.infinity:
        return out^
    var z_inv = _fe52_inv(point.z)
    var z_inv2 = _fe52_sqr(z_inv)
    var z_inv3 = _fe52_mul(z_inv2, z_inv)
    out.x = _fe52_mul(point.x, z_inv2)
    out.y = _fe52_mul(point.y, z_inv3)
    out.infinity = False
    return out^


def _fe52_gej_double(ref a: Fe52Jacobian) -> Fe52Jacobian:
    var out = Fe52Jacobian()
    out.infinity = a.infinity
    if a.infinity:
        return out^
    if _fe52_normalizes_to_zero_var(a.y):
        return Fe52Jacobian()
    out.z = _fe52_mul(a.z, a.y)
    var s = _fe52_sqr(a.y)
    var l = _fe52_sqr(a.x)
    l = _fe52_mul_int(l, UInt32(3))
    l = _fe52_half(l)
    var t = _fe52_negate(s)
    t = _fe52_mul(t, a.x)
    out.x = _fe52_sqr(l)
    out.x = _fe52_add(out.x, t)
    out.x = _fe52_add(out.x, t)
    s = _fe52_sqr(s)
    t = _fe52_add(t, out.x)
    out.y = _fe52_mul(t, l)
    out.y = _fe52_add(out.y, s)
    out.y = _fe52_negate(out.y)
    out.infinity = False
    return out^


def _fe52_gej_add_ge_var(ref a: Fe52Jacobian, ref b: Fe52Point) -> Fe52Jacobian:
    if a.infinity:
        return _fe52_jacobian_from_affine(b)
    if b.infinity:
        return a.copy()

    var z12 = _fe52_sqr(a.z)
    var u1 = a.x.copy()
    var u2 = _fe52_mul(b.x, z12)
    var s1 = a.y.copy()
    var s2 = _fe52_mul(b.y, z12)
    s2 = _fe52_mul(s2, a.z)
    var h = _fe52_add(_fe52_negate(u1), u2)
    var i = _fe52_add(_fe52_negate(s2), s1)
    if _fe52_normalizes_to_zero_var(h):
        if _fe52_normalizes_to_zero_var(i):
            return _fe52_gej_double(a)
        return Fe52Jacobian()

    var out = Fe52Jacobian()
    out.infinity = False
    out.z = _fe52_mul(a.z, h)
    var h2 = _fe52_negate(_fe52_sqr(h))
    var h3 = _fe52_mul(h2, h)
    var t = _fe52_mul(u1, h2)
    out.x = _fe52_sqr(i)
    out.x = _fe52_add(out.x, h3)
    out.x = _fe52_add(out.x, t)
    out.x = _fe52_add(out.x, t)
    t = _fe52_add(t, out.x)
    out.y = _fe52_mul(t, i)
    h3 = _fe52_mul(h3, s1)
    out.y = _fe52_add(out.y, h3)
    return out^


def _fe52_gej_add_var(ref a: Fe52Jacobian, ref b: Fe52Jacobian) -> Fe52Jacobian:
    if a.infinity:
        return b.copy()
    if b.infinity:
        return a.copy()

    var z22 = _fe52_sqr(b.z)
    var z12 = _fe52_sqr(a.z)
    var u1 = _fe52_mul(a.x, z22)
    var u2 = _fe52_mul(b.x, z12)
    var s1 = _fe52_mul(_fe52_mul(a.y, z22), b.z)
    var s2 = _fe52_mul(_fe52_mul(b.y, z12), a.z)
    var h = _fe52_add(_fe52_negate(u1), u2)
    var i = _fe52_add(_fe52_negate(s2), s1)
    if _fe52_normalizes_to_zero_var(h):
        if _fe52_normalizes_to_zero_var(i):
            return _fe52_gej_double(a)
        return Fe52Jacobian()

    var t = _fe52_mul(h, b.z)
    var h2 = _fe52_negate(_fe52_sqr(h))
    var h3 = _fe52_mul(h2, h)
    var tt = _fe52_mul(u1, h2)
    var x3 = _fe52_sqr(i)
    x3 = _fe52_add(x3, h3)
    x3 = _fe52_add(x3, tt)
    x3 = _fe52_add(x3, tt)
    var ty = _fe52_add(tt, x3)
    var y3 = _fe52_mul(ty, i)
    h3 = _fe52_mul(h3, s1)
    y3 = _fe52_add(y3, h3)

    var out = Fe52Jacobian()
    out.x = x3^
    out.y = y3^
    out.z = _fe52_mul(a.z, t)
    out.infinity = False
    return out^


def _fe52_scalar_mul_jacobian(ref scalar: U256, ref point: Point) -> Fe52Jacobian:
    var result = Fe52Jacobian()
    if _is_zero(scalar) or point.infinity:
        return result^
    var fe_point = _fe52_point_from_point(point)
    for j in range(256):
        var bit_index = 255 - j
        if not result.infinity:
            result = _fe52_gej_double(result)
        if _bit(scalar, bit_index):
            result = _fe52_gej_add_ge_var(result, fe_point)
    return result^


def _fe52_point_neg(ref point: Fe52Point) -> Fe52Point:
    if point.infinity:
        return point.copy()
    var out = point.copy()
    out.y = _fe52_negate(out.y)
    return out^


def _fe52_ge_mul_beta(ref point: Fe52Point) -> Fe52Point:
    if point.infinity:
        return point.copy()
    var out = point.copy()
    out.x = _fe52_mul(out.x, _fe52_from_u256(_beta()))
    return out^


def _fe52_ge_set_gej_zinv(ref point: Fe52Jacobian, ref z_inv: Fe52) -> Fe52Point:
    var out = Fe52Point()
    if point.infinity:
        return out^
    var z_inv2 = _fe52_sqr(z_inv)
    var z_inv3 = _fe52_mul(z_inv2, z_inv)
    out.x = _fe52_mul(point.x, z_inv2)
    out.y = _fe52_mul(point.y, z_inv3)
    out.infinity = False
    return out^


def _fe52_set_all_gej_to_affine(ref points: List[Fe52Jacobian]) raises -> List[Fe52Point]:
    var out = List[Fe52Point]()
    var count = len(points)
    if count == 0:
        return out^
    var prefixes = List[Fe52]()
    for i in range(count):
        if points[i].infinity:
            raise Error("unexpected infinity in Fe52 Jacobian odd-multiple table")
        if i == 0:
            prefixes.append(points[i].z.copy())
        else:
            prefixes.append(_fe52_mul(prefixes[i - 1], points[i].z))
        out.append(Fe52Point())

    var inv = _fe52_inv(prefixes[count - 1])
    var i = count - 1
    while i > 0:
        var z_inv = _fe52_mul(prefixes[i - 1], inv)
        inv = _fe52_mul(inv, points[i].z)
        out[i] = _fe52_ge_set_gej_zinv(points[i], z_inv)
        i -= 1
    out[0] = _fe52_ge_set_gej_zinv(points[0], inv)
    return out^


def _fe52_odd_multiples(ref point: Point, count: Int) raises -> List[Fe52Point]:
    return _fe52_odd_multiples_from_fe52(_fe52_point_from_point(point), count)


def _fe52_odd_multiples_from_fe52(ref point: Fe52Point, count: Int) raises -> List[Fe52Point]:
    var table = List[Fe52Jacobian]()
    if count <= 0:
        return List[Fe52Point]()
    var point_j = _fe52_jacobian_from_affine(point)
    table.append(point_j.copy())
    if count == 1:
        return _fe52_set_all_gej_to_affine(table)
    var two_point = _fe52_gej_double(point_j)
    for i in range(1, count):
        table.append(_fe52_gej_add_var(table[i - 1], two_point))
    return _fe52_set_all_gej_to_affine(table)


def _fe52_wnaf_table_add(mut result: Fe52Jacobian, ref table: List[Fe52Point], digit: Int) raises -> Fe52Jacobian:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = table[table_index].copy()
    if digit < 0:
        point = _fe52_point_neg(point)
    return _fe52_gej_add_ge_var(result, point)


def _fe52_wnaf_table_add_signed(mut result: Fe52Jacobian, ref table: List[Fe52Point], digit: Int, table_negated: Bool) raises -> Fe52Jacobian:
    if digit == 0:
        return result.copy()
    var effective_digit = digit
    if table_negated:
        effective_digit = 0 - effective_digit
    return _fe52_wnaf_table_add(result, table, effective_digit)


def _fe52_wnaf_generator_add(mut result: Fe52Jacobian, digit: Int) raises -> Fe52Jacobian:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = _fe52_point_from_point(_generator_odd_multiple(table_index))
    if digit < 0:
        point = _fe52_point_neg(point)
    return _fe52_gej_add_ge_var(result, point)


def _fe52_generator_odd_table(count: Int) raises -> List[Fe52Point]:
    var table = List[Fe52Point]()
    for i in range(count):
        table.append(_fe52_point_from_point(_generator_odd_multiple(i)))
    return table^


def _fe52_point_table_copy(ref table: List[Fe52Point]) -> List[Fe52Point]:
    var out = List[Fe52Point]()
    for i in range(len(table)):
        out.append(table[i].copy())
    return out^


def _fe52_point_table_neg(ref table: List[Fe52Point]) -> List[Fe52Point]:
    var out = List[Fe52Point]()
    for i in range(len(table)):
        out.append(_fe52_point_neg(table[i]))
    return out^


def _fe52_point_table_beta(ref table: List[Fe52Point]) -> List[Fe52Point]:
    var out = List[Fe52Point]()
    for i in range(len(table)):
        out.append(_fe52_ge_mul_beta(table[i]))
    return out^


def _fe52_double_base_mul(ref s: U256, ref generator: Point, ref e: U256, ref pubkey: Point) -> Fe52Jacobian:
    var result = Fe52Jacobian()
    var fe_generator = _fe52_point_from_point(generator)
    var fe_pubkey = _fe52_point_from_point(pubkey)
    for j in range(256):
        var bit_index = 255 - j
        if not result.infinity:
            result = _fe52_gej_double(result)
        if _bit(s, bit_index):
            result = _fe52_gej_add_ge_var(result, fe_generator)
        if _bit(e, bit_index):
            result = _fe52_gej_add_ge_var(result, fe_pubkey)
    return result^


def _fe52_double_base_mul_wnaf(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Point) raises -> Fe52Jacobian:
    return _fe52_double_base_mul_wnaf_fe52(g_scalar, p_scalar, _fe52_point_from_point(pubkey))


def _fe52_double_base_mul_wnaf_fe52(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Fe52Point) raises -> Fe52Jacobian:
    var width = 5
    var g_wnaf = _wnaf_recode(g_scalar, width)
    var p_wnaf = _wnaf_recode(p_scalar, width)
    var p_table = _fe52_odd_multiples_from_fe52(pubkey, 8)
    var max_len = len(g_wnaf)
    if len(p_wnaf) > max_len:
        max_len = len(p_wnaf)

    var result = Fe52Jacobian()
    for j in range(max_len):
        var i = max_len - 1 - j
        if not result.infinity:
            result = _fe52_gej_double(result)
        if i < len(g_wnaf):
            result = _fe52_wnaf_generator_add(result, g_wnaf[i])
        if i < len(p_wnaf):
            result = _fe52_wnaf_table_add(result, p_table, p_wnaf[i])
    return result^


def _fe52_double_base_mul_wnaf_glv(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Point) raises -> Fe52Jacobian:
    var width = 5
    var generator = _generator()
    var g_split = _endo_split(g_scalar, generator)
    var p_split = _endo_split(p_scalar, pubkey)
    var g1_wnaf = _wnaf_recode(g_split.s1, width)
    var g2_wnaf = _wnaf_recode(g_split.s2, width)
    var p1_wnaf = _wnaf_recode(p_split.s1, width)
    var p2_wnaf = _wnaf_recode(p_split.s2, width)

    var g_table = _fe52_generator_odd_table(8)
    var beta_g_table = _fe52_point_table_beta(g_table)
    var q_table = _fe52_odd_multiples(pubkey, 8)
    var beta_p_table = _fe52_point_table_beta(q_table)

    var max_len = len(g1_wnaf)
    if len(g2_wnaf) > max_len:
        max_len = len(g2_wnaf)
    if len(p1_wnaf) > max_len:
        max_len = len(p1_wnaf)
    if len(p2_wnaf) > max_len:
        max_len = len(p2_wnaf)

    var result = Fe52Jacobian()
    for j in range(max_len):
        var i = max_len - 1 - j
        if not result.infinity:
            result = _fe52_gej_double(result)
        if i < len(g1_wnaf):
            result = _fe52_wnaf_table_add_signed(result, g_table, g1_wnaf[i], g_split.s1_negated)
        if i < len(g2_wnaf):
            result = _fe52_wnaf_table_add_signed(result, beta_g_table, g2_wnaf[i], g_split.s2_negated)
        if i < len(p1_wnaf):
            result = _fe52_wnaf_table_add_signed(result, q_table, p1_wnaf[i], p_split.s1_negated)
        if i < len(p2_wnaf):
            result = _fe52_wnaf_table_add_signed(result, beta_p_table, p2_wnaf[i], p_split.s2_negated)
    return result^


def _from_be32(ref bytes: List[UInt8]) raises -> U256:
    if len(bytes) != 32:
        raise Error("invalid u256 byte length")
    var out = U256()
    for limb in range(4):
        var offset = 24 - limb * 8
        out.limbs[limb] = (
            (UInt64(bytes[offset]) << UInt64(56))
            | (UInt64(bytes[offset + 1]) << UInt64(48))
            | (UInt64(bytes[offset + 2]) << UInt64(40))
            | (UInt64(bytes[offset + 3]) << UInt64(32))
            | (UInt64(bytes[offset + 4]) << UInt64(24))
            | (UInt64(bytes[offset + 5]) << UInt64(16))
            | (UInt64(bytes[offset + 6]) << UInt64(8))
            | UInt64(bytes[offset + 7])
        )
    return out^


def _to_be32(ref value: U256) -> List[UInt8]:
    var out = List[UInt8]()
    for j in range(4):
        var limb = value.limbs[3 - j]
        out.append(UInt8((limb >> UInt64(56)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(48)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(40)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(32)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(24)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(16)) & UInt64(0xFF)))
        out.append(UInt8((limb >> UInt64(8)) & UInt64(0xFF)))
        out.append(UInt8(limb & UInt64(0xFF)))
    return out^


def _fe_add(ref a: U256, ref b: U256) -> U256:
    var p = _field_p()
    return _add_mod(a, b, p)


def _fe_sub(ref a: U256, ref b: U256) -> U256:
    var p = _field_p()
    return _sub_mod(a, b, p)


def _fe_mul(ref a: U256, ref b: U256) -> U256:
    return _mul_mod_field_fast(a, b)


def _fe_sqr(ref a: U256) -> U256:
    return _sqr_mod_field_fast(a)


def _fe_inv(ref a: U256) -> U256:
    var blocks = _fe_pow_blocks(a)
    var out = _fe_sqr_n(blocks.x223, 23)
    out = _fe_mul(out, blocks.x22)
    out = _fe_sqr_n(out, 5)
    out = _fe_mul(out, a)
    out = _fe_sqr_n(out, 3)
    out = _fe_mul(out, blocks.x2)
    out = _fe_sqr_n(out, 2)
    out = _fe_mul(out, a)
    return out^


def _fe_sqrt(ref a: U256) -> U256:
    var blocks = _fe_pow_blocks(a)
    var out = _fe_sqr_n(blocks.x223, 23)
    out = _fe_mul(out, blocks.x22)
    out = _fe_sqr_n(out, 6)
    out = _fe_mul(out, blocks.x2)
    out = _fe_sqr(out)
    out = _fe_sqr(out)
    return out^


def _scalar_add(ref a: U256, ref b: U256) -> U256:
    var n = _scalar_n()
    return _add_mod(a, b, n)


def _scalar_mul_mod(ref a: U256, ref b: U256) -> U256:
    return _mul_mod_scalar_fast(a, b)


def _scalar_inv(ref a: U256) -> U256:
    var n = _scalar_n()
    var u = _reduce_once(a, n)
    var v = n.copy()
    var x1 = _one()
    var x2 = _zero()
    while not _is_one_value(u) and not _is_one_value(v):
        while not _is_odd(u):
            u = _shr1(u)
            x1 = _scalar_half(x1)
        while not _is_odd(v):
            v = _shr1(v)
            x2 = _scalar_half(x2)
        if _cmp(u, v) >= 0:
            u = _sub_raw(u, v)
            x1 = _sub_mod(x1, x2, n)
        else:
            v = _sub_raw(v, u)
            x2 = _sub_mod(x2, x1, n)
    if _is_one_value(u):
        return x1^
    return x2^


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


def _jacobian_add(ref a: JacobianPoint, ref b: JacobianPoint) -> JacobianPoint:
    if a.infinity:
        return b.copy()
    if b.infinity:
        return a.copy()

    var z22 = _fe_sqr(b.z)
    var z12 = _fe_sqr(a.z)
    var u1 = _fe_mul(a.x, z22)
    var u2 = _fe_mul(b.x, z12)
    var s1 = _fe_mul(_fe_mul(a.y, z22), b.z)
    var s2 = _fe_mul(_fe_mul(b.y, z12), a.z)
    var h = _fe_sub(u2, u1)
    var i = _fe_sub(s1, s2)
    if _is_zero(h):
        if _is_zero(i):
            return _jacobian_double(a)
        return JacobianPoint()

    var t = _fe_mul(h, b.z)
    var h2 = _fe_sub(_zero(), _fe_sqr(h))
    var h3 = _fe_mul(h2, h)
    var tt = _fe_mul(u1, h2)
    var x3 = _fe_sqr(i)
    x3 = _fe_add(x3, h3)
    x3 = _fe_add(x3, tt)
    x3 = _fe_add(x3, tt)
    var ty = _fe_add(tt, x3)
    var y3 = _fe_mul(ty, i)
    h3 = _fe_mul(h3, s1)
    y3 = _fe_add(y3, h3)

    var out = JacobianPoint()
    out.x = x3^
    out.y = y3^
    out.z = _fe_mul(a.z, t)
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


def _wnaf_recode(ref scalar: U256, width: Int) -> List[Int]:
    var digits = List[Int]()
    var k = scalar.copy()
    var base = 1
    for _ in range(width):
        base *= 2
    var half = base // 2
    var mask = UInt64(base - 1)
    while not _is_zero(k):
        var digit = 0
        if _is_odd(k):
            digit = Int(k.limbs[0] & mask)
            if digit > half:
                digit -= base
            if digit > 0:
                k = _sub_small_raw(k, UInt32(digit))
            else:
                k = _add_small_raw(k, UInt32(0 - digit))
        digits.append(digit)
        k = _shr1(k)
    return digits^


def _wnaf_nonzero_count(ref digits: List[Int]) -> Int:
    var count = 0
    for i in range(len(digits)):
        if digits[i] != 0:
            count += 1
    return count


def _fe52_glv_loop_stats(ref g_scalar: U256, ref p_scalar: U256) -> Fe52GlvLoopStats:
    var width = 5
    var stats = Fe52GlvLoopStats()
    var g_wnaf = _wnaf_recode(g_scalar, width)
    var p_wnaf = _wnaf_recode(p_scalar, width)
    var generator = _generator()
    var g_split = _endo_split(g_scalar, generator)
    var p_split = _scalar_split_lambda(p_scalar)
    var p_split_s1 = p_split.s1.copy()
    var p_split_s2 = p_split.s2.copy()
    var n = _scalar_n()
    if _scalar_is_high(p_split_s1):
        p_split_s1 = _sub_mod(_zero(), p_split_s1, n)
    if _scalar_is_high(p_split_s2):
        p_split_s2 = _sub_mod(_zero(), p_split_s2, n)
    var g1_wnaf = _wnaf_recode(g_split.s1, width)
    var g2_wnaf = _wnaf_recode(g_split.s2, width)
    var p1_wnaf = _wnaf_recode(p_split_s1, width)
    var p2_wnaf = _wnaf_recode(p_split_s2, width)

    stats.g_wnaf_len = len(g_wnaf)
    stats.p_wnaf_len = len(p_wnaf)
    stats.g_split_1_wnaf_len = len(g1_wnaf)
    stats.g_split_2_wnaf_len = len(g2_wnaf)
    stats.p_split_1_wnaf_len = len(p1_wnaf)
    stats.p_split_2_wnaf_len = len(p2_wnaf)
    stats.plain_max_len = stats.g_wnaf_len
    if stats.p_wnaf_len > stats.plain_max_len:
        stats.plain_max_len = stats.p_wnaf_len
    stats.old_glv_max_len = stats.g_wnaf_len
    if stats.p_split_1_wnaf_len > stats.old_glv_max_len:
        stats.old_glv_max_len = stats.p_split_1_wnaf_len
    if stats.p_split_2_wnaf_len > stats.old_glv_max_len:
        stats.old_glv_max_len = stats.p_split_2_wnaf_len
    stats.glv_max_len = stats.g_split_1_wnaf_len
    if stats.g_split_2_wnaf_len > stats.glv_max_len:
        stats.glv_max_len = stats.g_split_2_wnaf_len
    if stats.p_split_1_wnaf_len > stats.glv_max_len:
        stats.glv_max_len = stats.p_split_1_wnaf_len
    if stats.p_split_2_wnaf_len > stats.glv_max_len:
        stats.glv_max_len = stats.p_split_2_wnaf_len
    stats.g_nonzero_digits = _wnaf_nonzero_count(g_wnaf)
    stats.p_nonzero_digits = _wnaf_nonzero_count(p_wnaf)
    stats.g_split_1_nonzero_digits = _wnaf_nonzero_count(g1_wnaf)
    stats.g_split_2_nonzero_digits = _wnaf_nonzero_count(g2_wnaf)
    stats.p_split_1_nonzero_digits = _wnaf_nonzero_count(p1_wnaf)
    stats.p_split_2_nonzero_digits = _wnaf_nonzero_count(p2_wnaf)
    return stats^


def _fe52_glv_setup_stats() -> Fe52GlvSetupStats:
    var stats = Fe52GlvSetupStats()
    stats.generator_table_builds = 1
    stats.beta_table_builds = 2
    stats.copied_tables = 0
    stats.negated_tables = 0
    stats.variable_point_table_builds = 1
    return stats^


def _odd_multiples_affine_reference(ref point: Point, count: Int) -> List[Point]:
    var table = List[Point]()
    if count <= 0:
        return table^
    table.append(point.copy())
    if count == 1:
        return table^
    var two_point = _point_double(point)
    for i in range(1, count):
        table.append(_point_add(table[i - 1], two_point))
    return table^


def _ge_set_gej_zinv(ref point: JacobianPoint, ref z_inv: U256) -> Point:
    var out = Point()
    if point.infinity:
        return out^
    var z_inv2 = _fe_sqr(z_inv)
    var z_inv3 = _fe_mul(z_inv2, z_inv)
    out.x = _fe_mul(point.x, z_inv2)
    out.y = _fe_mul(point.y, z_inv3)
    out.infinity = False
    return out^


def _set_all_gej_to_affine(ref points: List[JacobianPoint]) raises -> List[Point]:
    var out = List[Point]()
    var count = len(points)
    if count == 0:
        return out^
    var prefixes = List[U256]()
    for i in range(count):
        if points[i].infinity:
            raise Error("unexpected infinity in Jacobian odd-multiple table")
        if i == 0:
            prefixes.append(points[i].z.copy())
        else:
            prefixes.append(_fe_mul(prefixes[i - 1], points[i].z))
        out.append(Point())

    var inv = _fe_inv(prefixes[count - 1])
    var i = count - 1
    while i > 0:
        var z_inv = _fe_mul(prefixes[i - 1], inv)
        inv = _fe_mul(inv, points[i].z)
        out[i] = _ge_set_gej_zinv(points[i], z_inv)
        i -= 1
    out[0] = _ge_set_gej_zinv(points[0], inv)
    return out^


def _odd_multiples(ref point: Point, count: Int) raises -> List[Point]:
    var table = List[JacobianPoint]()
    if count <= 0:
        return List[Point]()
    var point_j = _jacobian_from_affine(point)
    table.append(point_j.copy())
    if count == 1:
        return _set_all_gej_to_affine(table)
    var two_point = _jacobian_double(point_j)
    for i in range(1, count):
        table.append(_jacobian_add(table[i - 1], two_point))
    return _set_all_gej_to_affine(table)


def _wnaf_table_add(mut result: JacobianPoint, ref table: List[Point], digit: Int) raises -> JacobianPoint:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = table[table_index].copy()
    if digit < 0:
        point = _point_neg(point)
    return _jacobian_add_affine(result, point)


def _wnaf_generator_add(mut result: JacobianPoint, digit: Int) raises -> JacobianPoint:
    if digit == 0:
        return result.copy()
    var abs_digit = digit
    if abs_digit < 0:
        abs_digit = 0 - abs_digit
    var table_index = (abs_digit - 1) // 2
    var point = _generator_odd_multiple(table_index)
    if digit < 0:
        point = _point_neg(point)
    return _jacobian_add_affine(result, point)


def _scalar_mul_shift_384(ref a: U256, ref b: U256) -> U256:
    var product = _schoolbook_product_4x64(a, b)
    var out = U256()
    out.limbs[0] = product[6]
    out.limbs[1] = product[7]
    out.limbs[2] = product[8]
    out.limbs[3] = UInt64(0)
    var roundbit = UInt32((product[5] >> UInt64(63)) & UInt64(1))
    return _add_small_raw(out, roundbit)


def _scalar_split_lambda(ref k: U256) -> EndoSplit:
    var g1 = _glv_g1()
    var g2 = _glv_g2()
    var minus_b1 = _minus_b1()
    var minus_b2 = _minus_b2()
    var lam = _lambda()
    var n = _scalar_n()

    var c1 = _scalar_mul_shift_384(k, g1)
    var c2 = _scalar_mul_shift_384(k, g2)
    c1 = _scalar_mul_mod(c1, minus_b1)
    c2 = _scalar_mul_mod(c2, minus_b2)

    var out = EndoSplit()
    out.s2 = _scalar_add(c1, c2)
    out.s1 = _scalar_mul_mod(out.s2, lam)
    out.s1 = _sub_mod(_zero(), out.s1, n)
    out.s1 = _scalar_add(out.s1, k)
    return out^


def _scalar_is_high(ref scalar: U256) -> Bool:
    var half_n = _scalar_half_n()
    return _cmp(scalar, half_n) > 0


def _ge_mul_beta(ref point: Point) -> Point:
    if point.infinity:
        return point.copy()
    var beta = _beta()
    var out = point.copy()
    out.x = _fe_mul(out.x, beta)
    return out^


def _endo_split(ref scalar: U256, ref point: Point) -> EndoSplit:
    var out = _scalar_split_lambda(scalar)
    var n = _scalar_n()
    out.p1 = point.copy()
    out.p2 = _ge_mul_beta(point)
    if _scalar_is_high(out.s1):
        out.s1 = _sub_mod(_zero(), out.s1, n)
        out.p1 = _point_neg(out.p1)
        out.s1_negated = True
    if _scalar_is_high(out.s2):
        out.s2 = _sub_mod(_zero(), out.s2, n)
        out.p2 = _point_neg(out.p2)
        out.s2_negated = True
    return out^


def _point_table_copy(ref table: List[Point]) -> List[Point]:
    var out = List[Point]()
    for i in range(len(table)):
        out.append(table[i].copy())
    return out^


def _point_table_neg(ref table: List[Point]) -> List[Point]:
    var out = List[Point]()
    for i in range(len(table)):
        out.append(_point_neg(table[i]))
    return out^


def _point_table_beta(ref table: List[Point]) -> List[Point]:
    var out = List[Point]()
    for i in range(len(table)):
        out.append(_ge_mul_beta(table[i]))
    return out^


def _double_base_mul_wnaf(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Point) raises -> JacobianPoint:
    var width = 5
    var g_wnaf = _wnaf_recode(g_scalar, width)
    var p_wnaf = _wnaf_recode(p_scalar, width)
    var p_table = _odd_multiples(pubkey, 8)
    var max_len = len(g_wnaf)
    if len(p_wnaf) > max_len:
        max_len = len(p_wnaf)

    var result = JacobianPoint()
    for j in range(max_len):
        var i = max_len - 1 - j
        if not result.infinity:
            result = _jacobian_double(result)
        if i < len(g_wnaf):
            result = _wnaf_generator_add(result, g_wnaf[i])
        if i < len(p_wnaf):
            result = _wnaf_table_add(result, p_table, p_wnaf[i])
    return result^


def _double_base_mul_wnaf_glv(ref g_scalar: U256, ref p_scalar: U256, ref pubkey: Point) raises -> JacobianPoint:
    var width = 5
    var g_wnaf = _wnaf_recode(g_scalar, width)
    var split = _endo_split(p_scalar, pubkey)
    var s1_wnaf = _wnaf_recode(split.s1, width)
    var s2_wnaf = _wnaf_recode(split.s2, width)

    var q_table = _odd_multiples(pubkey, 8)
    var s1_table = _point_table_copy(q_table)
    if split.s1_negated:
        s1_table = _point_table_neg(q_table)
    var beta_table = _point_table_beta(q_table)
    var s2_table = _point_table_copy(beta_table)
    if split.s2_negated:
        s2_table = _point_table_neg(beta_table)

    var max_len = len(g_wnaf)
    if len(s1_wnaf) > max_len:
        max_len = len(s1_wnaf)
    if len(s2_wnaf) > max_len:
        max_len = len(s2_wnaf)

    var result = JacobianPoint()
    for j in range(max_len):
        var i = max_len - 1 - j
        if not result.infinity:
            result = _jacobian_double(result)
        if i < len(g_wnaf):
            result = _wnaf_generator_add(result, g_wnaf[i])
        if i < len(s1_wnaf):
            result = _wnaf_table_add(result, s1_table, s1_wnaf[i])
        if i < len(s2_wnaf):
            result = _wnaf_table_add(result, s2_table, s2_wnaf[i])
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


def _parse_der_integer(ref der: List[UInt8], offset: Int, length: Int) raises -> U256:
    if length <= 0 or length > 33:
        raise Error("invalid DER integer length")
    if offset + length > len(der):
        raise Error("truncated DER integer")
    if (der[offset] & UInt8(0x80)) != UInt8(0):
        raise Error("negative DER integer")
    if length > 1 and der[offset] == UInt8(0) and (der[offset + 1] & UInt8(0x80)) == UInt8(0):
        raise Error("unnecessary DER integer padding")

    var start = offset
    var count = length
    if count == 33:
        if der[start] != UInt8(0):
            raise Error("oversized DER integer")
        start += 1
        count -= 1
    var out = List[UInt8]()
    for _ in range(32 - count):
        out.append(UInt8(0))
    for i in range(count):
        out.append(der[start + i])
    return _from_be32(out)


def _parse_ecdsa_der(ref der: List[UInt8]) raises -> EcdsaSignature:
    if len(der) < 8 or len(der) > 72:
        raise Error("invalid DER signature length")
    if der[0] != UInt8(0x30):
        raise Error("DER signature missing sequence")
    if Int(der[1]) != len(der) - 2:
        raise Error("DER sequence length mismatch")
    if der[2] != UInt8(0x02):
        raise Error("DER signature missing r integer")
    var r_len = Int(der[3])
    var s_marker = 4 + r_len
    if s_marker + 2 > len(der) or der[s_marker] != UInt8(0x02):
        raise Error("DER signature missing s integer")
    var s_len = Int(der[s_marker + 1])
    if s_marker + 2 + s_len != len(der):
        raise Error("DER signature trailing data")

    var out = EcdsaSignature()
    out.r = _parse_der_integer(der, 4, r_len)
    out.s = _parse_der_integer(der, s_marker + 2, s_len)
    return out^


def _parse_pubkey(ref pubkey: List[UInt8]) raises -> Point:
    var p = _field_p()
    if len(pubkey) == 33:
        if pubkey[0] != UInt8(0x02) and pubkey[0] != UInt8(0x03):
            raise Error("invalid compressed pubkey prefix")
        var x_bytes = List[UInt8]()
        for i in range(32):
            x_bytes.append(pubkey[i + 1])
        var x = _from_be32(x_bytes)
        if _cmp(x, p) >= 0:
            raise Error("pubkey x out of range")
        var point = _lift_x(x)
        var wants_odd = pubkey[0] == UInt8(0x03)
        if _is_odd(point.y) != wants_odd:
            point.y = _fe_sub(_zero(), point.y)
        return point^
    if len(pubkey) == 65:
        if pubkey[0] != UInt8(0x04):
            raise Error("invalid uncompressed pubkey prefix")
        var x_bytes = List[UInt8]()
        var y_bytes = List[UInt8]()
        for i in range(32):
            x_bytes.append(pubkey[i + 1])
            y_bytes.append(pubkey[i + 33])
        var x = _from_be32(x_bytes)
        var y = _from_be32(y_bytes)
        if _cmp(x, p) >= 0 or _cmp(y, p) >= 0:
            raise Error("pubkey coordinate out of range")
        var x2 = _fe_sqr(x)
        var x3 = _fe_mul(x2, x)
        var seven = _u256_from_u32(UInt32(7))
        var expected_y2 = _fe_add(x3, seven)
        var y2 = _fe_sqr(y)
        if not _eq(y2, expected_y2):
            raise Error("pubkey is not on secp256k1")
        var point = Point()
        point.x = x^
        point.y = y^
        point.infinity = False
        return point^
    raise Error("invalid pubkey length")


def pure_verify_ecdsa_der_bytes(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_FE52_WNAF)


def _pure_verify_ecdsa_der_bytes_with_mode(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
    use_wnaf: Bool,
) raises -> Int32:
    if use_wnaf:
        return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_FE52_WNAF)
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_REFERENCE)


def _pure_verify_ecdsa_der_bytes_fe52_wnaf(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    var n = _scalar_n()
    var sig = EcdsaSignature()
    var q = Fe52Point()
    try:
        sig = _parse_ecdsa_der(der)
        q = _fe52_parse_pubkey(pubkey)
    except:
        return MALFORMED
    if _is_zero(sig.r) or _is_zero(sig.s) or _cmp(sig.r, n) >= 0 or _cmp(sig.s, n) >= 0:
        return CONSENSUS_INVALID

    var half_n = _scalar_half_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)

    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52_jacobian_to_affine(_fe52_double_base_mul_wnaf_fe52(u1, u2, q))
    if point.infinity:
        return CONSENSUS_INVALID
    var x_mod_n = _reduce_once(_fe52_to_u256(point.x), n)
    if _eq(x_mod_n, sig.r):
        return VALID
    return CONSENSUS_INVALID


def _pure_verify_ecdsa_der_bytes_with_product_mode(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
    product_mode: Int,
) raises -> Int32:
    if (len(pubkey) != 33 and len(pubkey) != 65) or len(der) == 0 or len(der) > 72 or len(digest) != 32:
        return MALFORMED
    if product_mode == ECDSA_PRODUCT_FE52_WNAF:
        return _pure_verify_ecdsa_der_bytes_fe52_wnaf(pubkey, der, digest)
    var n = _scalar_n()
    var sig = EcdsaSignature()
    var q = Point()
    try:
        sig = _parse_ecdsa_der(der)
        q = _parse_pubkey(pubkey)
    except:
        return MALFORMED
    if _is_zero(sig.r) or _is_zero(sig.s) or _cmp(sig.r, n) >= 0 or _cmp(sig.s, n) >= 0:
        return CONSENSUS_INVALID

    var half_n = _scalar_half_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)

    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var product = JacobianPoint()
    if product_mode == ECDSA_PRODUCT_GLV:
        product = _double_base_mul_wnaf_glv(u1, u2, q)
    elif product_mode == ECDSA_PRODUCT_WNAF:
        product = _double_base_mul_wnaf(u1, u2, q)
    else:
        product = _double_base_mul(u1, _generator(), u2, q)
    var point = _jacobian_to_affine(product)
    if point.infinity:
        return CONSENSUS_INVALID
    var x_mod_n = _reduce_once(point.x, n)
    if _eq(x_mod_n, sig.r):
        return VALID
    return CONSENSUS_INVALID


def _pure_verify_schnorr_bytes_reference_4x64(
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


def _pure_verify_schnorr_bytes_fe52_wnaf(
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
    var pubkey = Fe52Point()
    try:
        pubkey = _fe52_lift_x(px)
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
    var r = _fe52_jacobian_to_affine(_fe52_double_base_mul_wnaf_fe52(s, neg_e, pubkey))
    if r.infinity:
        return CONSENSUS_INVALID
    if _is_odd(_fe52_to_u256(r.y)):
        return CONSENSUS_INVALID
    if not _eq(_fe52_to_u256(r.x), rx):
        return CONSENSUS_INVALID
    return VALID


def pure_verify_schnorr_bytes(
    ref xonly_pubkey: List[UInt8],
    ref signature: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    return _pure_verify_schnorr_bytes_fe52_wnaf(xonly_pubkey, signature, digest)


def _pure_verify_taproot_tweak_precomputed_reference_4x64(
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


def _pure_verify_taproot_tweak_precomputed_fe52(
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
    var internal = Fe52Point()
    try:
        internal = _fe52_lift_x(ix)
    except:
        return MALFORMED
    var tweak_scalar = _from_be32(tweak)
    if _cmp(tweak_scalar, n) >= 0:
        return MALFORMED
    var output = internal.copy()
    if not _is_zero(tweak_scalar):
        var tweaked = _fe52_scalar_mul_jacobian(tweak_scalar, _generator())
        tweaked = _fe52_gej_add_ge_var(tweaked, internal)
        output = _fe52_jacobian_to_affine(tweaked)
    if output.infinity:
        return MALFORMED
    var expected = _from_be32(expected_xonly)
    var output_parity = 0
    if _is_odd(_fe52_to_u256(output.y)):
        output_parity = 1
    if _eq(_fe52_to_u256(output.x), expected) and output_parity == expected_parity:
        return VALID
    return CONSENSUS_INVALID


def pure_verify_taproot_tweak_precomputed(
    ref internal_xonly: List[UInt8],
    ref tweak: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
) raises -> Int32:
    return _pure_verify_taproot_tweak_precomputed_fe52(
        internal_xonly,
        tweak,
        expected_xonly,
        expected_parity,
    )


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


def pure_test_u256_mul_field_fast(ref a: List[UInt8], ref b: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    return _to_be32(_fe_mul(_reduce_once(av, p), _reduce_once(bv, p)))


def pure_test_u256_mul_scalar_fast(ref a: List[UInt8], ref b: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var n = _scalar_n()
    return _to_be32(_scalar_mul_mod(_reduce_once(av, n), _reduce_once(bv, n)))


def pure_test_u256_square_field(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    return _to_be32(_fe_sqr(_reduce_once(av, p)))


def pure_test_u256_inv_field_fast(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    return _to_be32(_fe_inv(_reduce_once(av, p)))


def pure_test_u256_inv_field_reference(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    var exp = _field_p_minus_2()
    return _to_be32(_pow_mod_field(_reduce_once(av, p), exp))


def pure_test_u256_sqrt_field_fast(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    return _to_be32(_fe_sqrt(_reduce_once(av, p)))


def pure_test_u256_sqrt_field_reference(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    var exp = _field_sqrt_exp()
    return _to_be32(_pow_mod_field(_reduce_once(av, p), exp))


def pure_test_u256_inv_mod(ref a: List[UInt8], ref modulus: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var mv = _from_be32(modulus)
    var exp = _sub_raw(mv, _u256_from_u32(UInt32(2)))
    return _to_be32(_pow_mod(_reduce_once(av, mv), exp, mv))


def pure_test_fe52_roundtrip(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    return _to_be32(_fe52_to_u256(_fe52_from_u256(_reduce_once(av, p))))


def pure_test_fe52_add(ref a: List[UInt8], ref b: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    return _to_be32(_fe52_to_u256(_fe52_add(af, bf)))


def pure_test_fe52_sub_via_negate(ref a: List[UInt8], ref b: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    return _to_be32(_fe52_to_u256(_fe52_add(af, _fe52_negate(bf))))


def pure_test_fe52_mul(ref a: List[UInt8], ref b: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    return _to_be32(_fe52_to_u256(_fe52_mul(af, bf)))


def pure_test_fe52_sqr(ref a: List[UInt8]) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    return _to_be32(_fe52_to_u256(_fe52_sqr(af)))


def pure_test_fe52x4_add_lane(ref a: List[UInt8], ref b: List[UInt8], lane: Int) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    var out = _fe52x4_add(_fe52x4_from_fe52(af), _fe52x4_from_fe52(bf))
    return _to_be32(_fe52_to_u256(_fe52x4_lane_to_fe52(out, lane)))


def pure_test_fe52x4_mul_lane(ref a: List[UInt8], ref b: List[UInt8], lane: Int) raises -> List[UInt8]:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    var out = _fe52x4_mul(_fe52x4_from_fe52(af), _fe52x4_from_fe52(bf))
    return _to_be32(_fe52_to_u256(_fe52x4_lane_to_fe52(out, lane)))


def pure_test_fe52x4_sqr_lane(ref a: List[UInt8], lane: Int) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var out = _fe52x4_sqr(_fe52x4_from_fe52(af))
    return _to_be32(_fe52_to_u256(_fe52x4_lane_to_fe52(out, lane)))


def pure_test_fe52_mul_int(ref a: List[UInt8], scalar: UInt32) raises -> List[UInt8]:
    var av = _from_be32(a)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    return _to_be32(_fe52_to_u256(_fe52_mul_int(af, scalar)))


def pure_test_fe52_equal(ref a: List[UInt8], ref b: List[UInt8]) raises -> Bool:
    var av = _from_be32(a)
    var bv = _from_be32(b)
    var p = _field_p()
    var af = _fe52_from_u256(_reduce_once(av, p))
    var bf = _fe52_from_u256(_reduce_once(bv, p))
    return _fe52_equal(af, bf)


def pure_test_fe52_is_zero(ref a: List[UInt8]) raises -> Bool:
    var av = _from_be32(a)
    var p = _field_p()
    return _fe52_is_zero(_fe52_from_u256(_reduce_once(av, p)))


def pure_test_fe52_scalar_mul_g_x(ref scalar: List[UInt8]) raises -> List[UInt8]:
    var sv = _from_be32(scalar)
    var point = _fe52_jacobian_to_affine(_fe52_scalar_mul_jacobian(sv, _generator()))
    if point.infinity:
        raise Error("Fe52 scalar multiply returned infinity")
    return _to_be32(_fe52_to_u256(point.x))


def pure_test_fe52_scalar_mul_g_y(ref scalar: List[UInt8]) raises -> List[UInt8]:
    var sv = _from_be32(scalar)
    var point = _fe52_jacobian_to_affine(_fe52_scalar_mul_jacobian(sv, _generator()))
    if point.infinity:
        raise Error("Fe52 scalar multiply returned infinity")
    return _to_be32(_fe52_to_u256(point.y))


def pure_test_ecdsa_fe52_reference_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52_jacobian_to_affine(_fe52_double_base_mul(u1, _generator(), u2, q))
    if point.infinity:
        raise Error("Fe52 ECDSA reference product is infinity")
    return _to_be32(_fe52_to_u256(point.x))


def pure_test_ecdsa_fe52_wnaf_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _fe52_parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52_jacobian_to_affine(_fe52_double_base_mul_wnaf_fe52(u1, u2, q))
    if point.infinity:
        raise Error("Fe52 ECDSA wNAF product is infinity")
    return _to_be32(_fe52_to_u256(point.x))


def pure_test_ecdsa_fe52_wnaf_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_FE52_WNAF)


def pure_test_ecdsa_fe52_simd4_wnaf_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8], lane: Int) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _fe52_parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52x4_jacobian_to_affine(_fe52x4_double_base_mul_wnaf_identical(u1, u2, q))
    if point.infinity:
        raise Error("Fe52x4 ECDSA wNAF product is infinity")
    var lane_point = _fe52x4_point_lane_to_fe52(point, lane)
    return _to_be32(_fe52_to_u256(lane_point.x))


def _pure_bytes_equal(ref a: List[UInt8], ref b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def pure_test_ecdsa_fe52_simd4_wnaf_mismatches(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int:
    var expected = pure_test_ecdsa_fe52_wnaf_product_x(pubkey, der, digest)
    var mismatches = 0
    for lane in range(FE52_SIMD_LANES):
        var actual = pure_test_ecdsa_fe52_simd4_wnaf_product_x(pubkey, der, digest, lane)
        if not _pure_bytes_equal(actual, expected):
            mismatches += 1
    return mismatches


def pure_test_ecdsa_fe52_simd4_wnaf_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    if (len(pubkey) != 33 and len(pubkey) != 65) or len(der) == 0 or len(der) > 72 or len(digest) != 32:
        return MALFORMED
    var n = _scalar_n()
    var sig = EcdsaSignature()
    try:
        sig = _parse_ecdsa_der(der)
    except:
        return MALFORMED
    if _is_zero(sig.r) or _is_zero(sig.s) or _cmp(sig.r, n) >= 0 or _cmp(sig.s, n) >= 0:
        return CONSENSUS_INVALID

    var x = U256()
    try:
        x = _from_be32(pure_test_ecdsa_fe52_simd4_wnaf_product_x(pubkey, der, digest, 0))
    except:
        return MALFORMED
    var x_mod_n = _reduce_once(x, n)
    if _eq(x_mod_n, sig.r):
        return VALID
    return CONSENSUS_INVALID


def pure_test_ecdsa_fe52_glv_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52_jacobian_to_affine(_fe52_double_base_mul_wnaf_glv(u1, u2, q))
    if point.infinity:
        raise Error("Fe52 ECDSA GLV product is infinity")
    return _to_be32(_fe52_to_u256(point.x))


def pure_test_ecdsa_fe52_glv_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    if (len(pubkey) != 33 and len(pubkey) != 65) or len(der) == 0 or len(der) > 72 or len(digest) != 32:
        return MALFORMED
    var n = _scalar_n()
    var sig = EcdsaSignature()
    var q = Point()
    try:
        sig = _parse_ecdsa_der(der)
        q = _parse_pubkey(pubkey)
    except:
        return MALFORMED
    if _is_zero(sig.r) or _is_zero(sig.s) or _cmp(sig.r, n) >= 0 or _cmp(sig.s, n) >= 0:
        return CONSENSUS_INVALID

    var half_n = _scalar_half_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)

    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _fe52_jacobian_to_affine(_fe52_double_base_mul_wnaf_glv(u1, u2, q))
    if point.infinity:
        return CONSENSUS_INVALID
    var x_mod_n = _reduce_once(_fe52_to_u256(point.x), n)
    if _eq(x_mod_n, sig.r):
        return VALID
    return CONSENSUS_INVALID


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


def pure_test_schnorr_reference_result(ref xonly_pubkey: List[UInt8], ref signature: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_schnorr_bytes_reference_4x64(xonly_pubkey, signature, digest)


def pure_test_schnorr_fe52_wnaf_result(ref xonly_pubkey: List[UInt8], ref signature: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_schnorr_bytes_fe52_wnaf(xonly_pubkey, signature, digest)


def pure_test_taproot_tweak_reference_result(ref internal_xonly: List[UInt8], ref tweak: List[UInt8], ref expected_xonly: List[UInt8], expected_parity: Int) raises -> Int32:
    return _pure_verify_taproot_tweak_precomputed_reference_4x64(internal_xonly, tweak, expected_xonly, expected_parity)


def pure_test_taproot_tweak_fe52_result(ref internal_xonly: List[UInt8], ref tweak: List[UInt8], ref expected_xonly: List[UInt8], expected_parity: Int) raises -> Int32:
    return _pure_verify_taproot_tweak_precomputed_fe52(internal_xonly, tweak, expected_xonly, expected_parity)


def pure_test_ecdsa_parse_der(ref der: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var out = List[UInt8]()
    var r = _to_be32(sig.r)
    var s = _to_be32(sig.s)
    _append_bytes(out, r)
    _append_bytes(out, s)
    return out^


def pure_test_ecdsa_parse_pubkey_x(ref pubkey: List[UInt8]) raises -> List[UInt8]:
    var point = _parse_pubkey(pubkey)
    return _to_be32(point.x)


def pure_test_ecdsa_normalized_s(ref der: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    return _to_be32(sig.s)


def pure_test_ecdsa_inverse_s(ref der: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    return _to_be32(_scalar_inv(sig.s))


def pure_test_ecdsa_u_scalars(ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var out = List[UInt8]()
    _append_bytes(out, _to_be32(u1))
    _append_bytes(out, _to_be32(u2))
    return out^


def pure_test_glv_constants() -> Bool:
    var beta = _beta()
    var one = _one()
    var beta_for_square = beta.copy()
    var beta2 = _fe_mul(beta, beta_for_square)
    var beta3 = _fe_mul(beta2, beta)
    if not _eq(beta3, one):
        return False
    if _eq(beta, one):
        return False

    var lam = _lambda()
    var lam_for_square = lam.copy()
    var lambda2 = _scalar_mul_mod(lam, lam_for_square)
    var lambda3 = _scalar_mul_mod(lambda2, lam)
    if not _eq(lambda3, one):
        return False
    if _eq(lam, one):
        return False
    return True


def pure_test_scalar_split_lambda_identity(ref scalar: List[UInt8]) raises -> Bool:
    var n = _scalar_n()
    var k = _reduce_once(_from_be32(scalar), n)
    var split = _scalar_split_lambda(k)
    var lam = _lambda()
    var lambda_r2 = _scalar_mul_mod(lam, split.s2)
    var recomposed = _scalar_add(split.s1, lambda_r2)
    return _eq(recomposed, k)


def pure_test_endo_split_not_high(ref scalar: List[UInt8], ref pubkey: List[UInt8]) raises -> Bool:
    var n = _scalar_n()
    var k = _reduce_once(_from_be32(scalar), n)
    var q = _parse_pubkey(pubkey)
    var split = _endo_split(k, q)
    return not _scalar_is_high(split.s1) and not _scalar_is_high(split.s2)


def pure_test_generator_endo_split_not_high(ref scalar: List[UInt8]) raises -> Bool:
    var n = _scalar_n()
    var k = _reduce_once(_from_be32(scalar), n)
    var generator = _generator()
    var split = _endo_split(k, generator)
    return not _scalar_is_high(split.s1) and not _scalar_is_high(split.s2)


def pure_test_fe52_generator_beta_table_matches(count: Int) raises -> Bool:
    var table = _fe52_generator_odd_table(count)
    var beta_table = _fe52_point_table_beta(table)
    var beta = _fe52_from_u256(_beta())
    for i in range(count):
        var expected_x = _fe52_mul(table[i].x, beta)
        if not _fe52_equal(expected_x, beta_table[i].x):
            return False
        if not _fe52_equal(table[i].y, beta_table[i].y):
            return False
    return True


def pure_test_fe52_pubkey_beta_table_matches(ref pubkey: List[UInt8], count: Int) raises -> Bool:
    var q = _parse_pubkey(pubkey)
    var table = _fe52_odd_multiples(q, count)
    var beta_table = _fe52_point_table_beta(table)
    var beta = _fe52_from_u256(_beta())
    for i in range(count):
        var expected_x = _fe52_mul(table[i].x, beta)
        if not _fe52_equal(expected_x, beta_table[i].x):
            return False
        if not _fe52_equal(table[i].y, beta_table[i].y):
            return False
    return True


def _ecdsa_fe52_glv_loop_stats_for_vectors(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Fe52GlvLoopStats:
    var sig = _parse_ecdsa_der(der)
    _ = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    return _fe52_glv_loop_stats(u1, u2)


def pure_test_ecdsa_fe52_glv_old_max_len(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int:
    return _ecdsa_fe52_glv_loop_stats_for_vectors(pubkey, der, digest).old_glv_max_len


def pure_test_ecdsa_fe52_glv_max_len(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int:
    return _ecdsa_fe52_glv_loop_stats_for_vectors(pubkey, der, digest).glv_max_len


def pure_test_ecdsa_fe52_glv_loop_stats_json(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> String:
    var stats = _ecdsa_fe52_glv_loop_stats_for_vectors(pubkey, der, digest)
    return (
        String('{"g_wnaf_len":')
        + String(stats.g_wnaf_len)
        + String(',"p_wnaf_len":')
        + String(stats.p_wnaf_len)
        + String(',"g_split_1_wnaf_len":')
        + String(stats.g_split_1_wnaf_len)
        + String(',"g_split_2_wnaf_len":')
        + String(stats.g_split_2_wnaf_len)
        + String(',"p_split_1_wnaf_len":')
        + String(stats.p_split_1_wnaf_len)
        + String(',"p_split_2_wnaf_len":')
        + String(stats.p_split_2_wnaf_len)
        + String(',"plain_max_len":')
        + String(stats.plain_max_len)
        + String(',"old_glv_max_len":')
        + String(stats.old_glv_max_len)
        + String(',"fe52_glv_max_len":')
        + String(stats.glv_max_len)
        + String(',"max_len":')
        + String(stats.glv_max_len)
        + String(',"g_nonzero_digits":')
        + String(stats.g_nonzero_digits)
        + String(',"p_nonzero_digits":')
        + String(stats.p_nonzero_digits)
        + String(',"g_split_1_nonzero_digits":')
        + String(stats.g_split_1_nonzero_digits)
        + String(',"g_split_2_nonzero_digits":')
        + String(stats.g_split_2_nonzero_digits)
        + String(',"p_split_1_nonzero_digits":')
        + String(stats.p_split_1_nonzero_digits)
        + String(',"p_split_2_nonzero_digits":')
        + String(stats.p_split_2_nonzero_digits)
        + String("}")
    )


def pure_test_ecdsa_fe52_glv_setup_stats_json() -> String:
    var stats = _fe52_glv_setup_stats()
    return (
        String('{"generator_table_builds":')
        + String(stats.generator_table_builds)
        + String(',"beta_table_builds":')
        + String(stats.beta_table_builds)
        + String(',"copied_tables":')
        + String(stats.copied_tables)
        + String(',"negated_tables":')
        + String(stats.negated_tables)
        + String(',"variable_point_table_builds":')
        + String(stats.variable_point_table_builds)
        + String("}")
    )


def pure_test_ecdsa_reference_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _jacobian_to_affine(_double_base_mul(u1, _generator(), u2, q))
    if point.infinity:
        raise Error("ECDSA reference product is infinity")
    return _to_be32(point.x)


def pure_test_ecdsa_wnaf_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _jacobian_to_affine(_double_base_mul_wnaf(u1, u2, q))
    if point.infinity:
        raise Error("ECDSA wNAF product is infinity")
    return _to_be32(point.x)


def pure_test_ecdsa_glv_product_x(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> List[UInt8]:
    var sig = _parse_ecdsa_der(der)
    var q = _parse_pubkey(pubkey)
    var half_n = _scalar_half_n()
    var n = _scalar_n()
    if _cmp(sig.s, half_n) > 0:
        sig.s = _sub_mod(_zero(), sig.s, n)
    var z = _from_be32(digest)
    z = _reduce_once(z, n)
    var w = _scalar_inv(sig.s)
    var u1 = _scalar_mul_mod(z, w)
    var u2 = _scalar_mul_mod(sig.r, w)
    var point = _jacobian_to_affine(_double_base_mul_wnaf_glv(u1, u2, q))
    if point.infinity:
        raise Error("ECDSA GLV product is infinity")
    return _to_be32(point.x)


def pure_test_ecdsa_reference_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_REFERENCE)


def pure_test_ecdsa_wnaf_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_WNAF)


def pure_test_ecdsa_glv_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_product_mode(pubkey, der, digest, ECDSA_PRODUCT_GLV)


def _point_lists_equal(ref a: List[Point], ref b: List[Point]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i].infinity != b[i].infinity:
            return False
        if not a[i].infinity:
            if not _eq(a[i].x, b[i].x) or not _eq(a[i].y, b[i].y):
                return False
    return True


def pure_test_odd_multiples_match_generator(count: Int) raises -> Bool:
    var generator = _generator()
    var reference = _odd_multiples_affine_reference(generator, count)
    var batched = _odd_multiples(generator, count)
    return _point_lists_equal(reference, batched)


def pure_test_odd_multiples_match_pubkey(ref pubkey: List[UInt8], count: Int) raises -> Bool:
    var point = _parse_pubkey(pubkey)
    var reference = _odd_multiples_affine_reference(point, count)
    var batched = _odd_multiples(point, count)
    return _point_lists_equal(reference, batched)


def pure_test_odd_multiples_match_xonly(ref xonly: List[UInt8], count: Int) raises -> Bool:
    var x = _from_be32(xonly)
    var point = _lift_x(x)
    var reference = _odd_multiples_affine_reference(point, count)
    var batched = _odd_multiples(point, count)
    return _point_lists_equal(reference, batched)
