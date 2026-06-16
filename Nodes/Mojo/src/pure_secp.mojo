from std.collections import List


def pure_backend_label() -> String:
    return String("mojo-pure-secp256k1")


def pure_verify_ecdsa_der_bytes(
    ref pubkey: List[UInt8],
    ref der: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    _ = len(pubkey)
    _ = len(der)
    _ = len(digest)
    return 3


def pure_verify_schnorr_bytes(
    ref xonly_pubkey: List[UInt8],
    ref signature: List[UInt8],
    ref digest: List[UInt8],
) raises -> Int32:
    _ = len(xonly_pubkey)
    _ = len(signature)
    _ = len(digest)
    return 3


def pure_verify_taproot_tweak_precomputed(
    ref internal_xonly: List[UInt8],
    ref tweak: List[UInt8],
    ref expected_xonly: List[UInt8],
    expected_parity: Int,
) raises -> Int32:
    _ = len(internal_xonly)
    _ = len(tweak)
    _ = len(expected_xonly)
    _ = expected_parity
    return 3
