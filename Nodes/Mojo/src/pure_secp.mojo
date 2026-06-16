from std.collections import InlineArray, List


comptime VALID = Int32(0)
comptime CONSENSUS_INVALID = Int32(1)
comptime MALFORMED = Int32(2)
comptime UNSUPPORTED = Int32(3)


struct U256(Copyable):
    var limbs: InlineArray[UInt64, 4]

    def __init__(out self):
        self.limbs = InlineArray[UInt64, 4](fill=UInt64(0))


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
    var exp = _field_p_minus_2()
    return _pow_mod_field(a, exp)


def _fe_sqrt(ref a: U256) -> U256:
    var exp = _field_sqrt_exp()
    return _pow_mod_field(a, exp)


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


def _odd_multiples(ref point: Point, count: Int) -> List[Point]:
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
    return _pure_verify_ecdsa_der_bytes_with_mode(pubkey, der, digest, True)


def _pure_verify_ecdsa_der_bytes_with_mode(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
    use_wnaf: Bool,
) raises -> Int32:
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
    var product = JacobianPoint()
    if use_wnaf:
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


def pure_test_ecdsa_reference_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_mode(pubkey, der, digest, False)


def pure_test_ecdsa_wnaf_result(ref pubkey: List[UInt8], ref der: List[UInt8], ref digest: List[UInt8]) raises -> Int32:
    return _pure_verify_ecdsa_der_bytes_with_mode(pubkey, der, digest, True)
