from __future__ import annotations

# secp256k1 parameters
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
A = 0
B = 7
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


class Secp256k1Error(ValueError):
    pass


def _modinv(value: int, modulus: int) -> int:
    return pow(value, -1, modulus)


def _decompress_pubkey(data: bytes) -> tuple[int, int]:
    if len(data) == 33 and data[0] in (2, 3):
        x = int.from_bytes(data[1:], "big")
        y_squared = (pow(x, 3, P) + B) % P
        y = pow(y_squared, (P + 1) // 4, P)
        if (y % 2 == 0) != (data[0] == 2):
            y = P - y
        return x, y
    if len(data) == 65 and data[0] == 4:
        x = int.from_bytes(data[1:33], "big")
        y = int.from_bytes(data[33:65], "big")
        return x, y
    raise Secp256k1Error("invalid public key encoding")


def _point_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None) -> tuple[int, int] | None:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        slope = (3 * x1 * x1 + A) * _modinv(2 * y1, P) % P
    else:
        slope = (y2 - y1) * _modinv(x2 - x1, P) % P
    x3 = (slope * slope - x1 - x2) % P
    y3 = (slope * (x1 - x3) - y1) % P
    return x3, y3


def _scalar_mult(k: int, point: tuple[int, int]) -> tuple[int, int] | None:
    result: tuple[int, int] | None = None
    addend = point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def _parse_der_signature(data: bytes) -> tuple[int, int]:
    if len(data) < 8 or data[0] != 0x30:
        raise Secp256k1Error("invalid DER signature")
    if data[1] + 2 != len(data):
        raise Secp256k1Error("invalid DER signature length")
    if data[2] != 0x02:
        raise Secp256k1Error("invalid DER signature r marker")
    r_len = data[3]
    r = int.from_bytes(data[4 : 4 + r_len], "big")
    offset = 4 + r_len
    if data[offset] != 0x02:
        raise Secp256k1Error("invalid DER signature s marker")
    s_len = data[offset + 1]
    s = int.from_bytes(data[offset + 2 : offset + 2 + s_len], "big")
    if r <= 0 or s <= 0 or r >= N or s >= N:
        raise Secp256k1Error("signature r/s out of range")
    return r, s


def lift_x_only_pubkey(x_coord: int) -> tuple[int, int] | None:
    """BIP340 secp256k1 point lift from X coordinate (reject invalid curve / overflow)."""
    if x_coord >= P:
        return None
    y_squared = (pow(x_coord, 3, P) + B) % P
    y = pow(y_squared, (P + 1) // 4, P)
    if pow(y, 2, P) != y_squared:
        return None
    if y & 1:
        y = P - y
    return x_coord, y


def _has_even_y(point: tuple[int, int]) -> bool:
    return point[1] % 2 == 0


def verify_schnorr_signature(pubkey_xonly: bytes, message_hash: bytes, signature: bytes) -> bool:
    """
    Verify a 64-byte BIP340 Schnorr signature for a 32-byte x-only public key and 32-byte message.
    Uses tagged_hash from BIP340 for the challenge.
    """
    from pybitnode.consensus.script.sighash import bitcoin_tagged_hash

    if len(pubkey_xonly) != 32 or len(message_hash) != 32 or len(signature) != 64:
        return False
    try:
        x_pub = int.from_bytes(pubkey_xonly, "big")
        pubkey_point = lift_x_only_pubkey(x_pub)
        if pubkey_point is None:
            return False
        rx = int.from_bytes(signature[:32], "big")
        s = int.from_bytes(signature[32:], "big")
        if rx >= P or s >= N:
            return False
        e = (
            int.from_bytes(
                bitcoin_tagged_hash("BIP0340/challenge", signature[:32] + pubkey_xonly + message_hash),
                "big",
            )
            % N
        )
        g_point = (Gx, Gy)
        lhs = _scalar_mult(s, g_point)
        rhs_adj = _scalar_mult((N - e) % N, pubkey_point)
        r_pt = _point_add(lhs, rhs_adj)
        if r_pt is None:
            return False
        xr, yr = r_pt
        return _has_even_y((xr, yr)) and (xr % P) == (rx % P)
    except (Secp256k1Error, ValueError):
        return False


def sign_bip340_schnorr(secret_key_int: int, message: bytes) -> bytes:
    """
    64-byte BIP340 Schnorr signature (bitcoin/bips/bip-0340/reference.py semantics).
    """
    from pybitnode.consensus.script.sighash import bitcoin_tagged_hash

    import hashlib

    d0 = secret_key_int % N
    if d0 <= 0 or d0 >= N:
        raise Secp256k1Error("invalid secret key")
    p_point = _scalar_mult(d0, (Gx, Gy))
    if p_point is None:
        raise Secp256k1Error("invalid public point")
    d = d0
    if not _has_even_y(p_point):
        d = N - d
        p_point = _scalar_mult(d, (Gx, Gy))
        if p_point is None:
            raise Secp256k1Error("invalid public point")
    pk_xbytes = p_point[0].to_bytes(32, "big")
    aux_rand = hashlib.sha256(b"pbn(aux)" + d.to_bytes(32, "big") + message).digest()
    t = bytes(x ^ y for x, y in zip(d.to_bytes(32, "big"), bitcoin_tagged_hash("BIP0340/aux", aux_rand)))
    k0 = int.from_bytes(bitcoin_tagged_hash("BIP0340/nonce", t + pk_xbytes + message), "big") % N
    if k0 == 0:
        raise Secp256k1Error("signing failure (retry)")
    r_point = _scalar_mult(k0, (Gx, Gy))
    if r_point is None:
        raise Secp256k1Error("signing failure (retry)")
    k = k0 if _has_even_y(r_point) else N - k0
    e = int.from_bytes(
        bitcoin_tagged_hash(
            "BIP0340/challenge",
            r_point[0].to_bytes(32, "big") + pk_xbytes + message,
        ),
        "big",
    ) % N
    sig = r_point[0].to_bytes(32, "big") + ((k + e * d) % N).to_bytes(32, "big")
    if not verify_schnorr_signature(pk_xbytes, message, sig):
        raise Secp256k1Error("internal Schnorr signing failed sanity check")
    return sig


def verify_der_signature(pubkey: bytes, message_hash: bytes, signature: bytes) -> bool:
    if len(message_hash) != 32:
        raise Secp256k1Error("message hash must be 32 bytes")
    try:
        r, s = _parse_der_signature(signature)
        qx, qy = _decompress_pubkey(pubkey)
        z = int.from_bytes(message_hash, "big")
        w = _modinv(s, N)
        u1 = (z * w) % N
        u2 = (r * w) % N
        g_point = (Gx, Gy)
        q_point = (qx, qy)
        point = _point_add(_scalar_mult(u1, g_point), _scalar_mult(u2, q_point))
        if point is None:
            return False
        x, _y = point
        return (x % N) == r
    except Secp256k1Error:
        return False


def sign_der(private_key: int, message_hash: bytes) -> bytes:
    if not (0 < private_key < N):
        raise Secp256k1Error("invalid private key")
    if len(message_hash) != 32:
        raise Secp256k1Error("message hash must be 32 bytes")
    z = int.from_bytes(message_hash, "big")
    for nonce in range(1, 1000):
        k = nonce
        point = _scalar_mult(k, (Gx, Gy))
        if point is None:
            continue
        r = point[0] % N
        if r == 0:
            continue
        s = (_modinv(k, N) * (z + r * private_key)) % N
        if s == 0:
            continue
        if s > N // 2:
            s = N - s
        r_bytes = r.to_bytes(32, "big").lstrip(b"\x00") or b"\x00"
        s_bytes = s.to_bytes(32, "big").lstrip(b"\x00") or b"\x00"
        return (
            bytes([0x30, 4 + len(r_bytes) + len(s_bytes), 2, len(r_bytes)])
            + r_bytes
            + bytes([2, len(s_bytes)])
            + s_bytes
        )
    raise Secp256k1Error("failed to sign message")
