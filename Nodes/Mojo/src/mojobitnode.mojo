from std.collections import List
from std.ffi import OwnedDLHandle
from std.memory.unsafe_pointer import alloc
from std.os import getenv
from std.pathlib import Path
from std.sys import argv

from block_core import Native, local_reference_proof
from pure_secp import (
    pure_test_ecdsa_inverse_s,
    pure_test_ecdsa_normalized_s,
    pure_test_ecdsa_parse_der,
    pure_test_ecdsa_parse_pubkey_x,
    pure_test_ecdsa_fe52_reference_product_x,
    pure_test_ecdsa_fe52_glv_product_x,
    pure_test_ecdsa_fe52_glv_result,
    pure_test_ecdsa_fe52_wnaf_product_x,
    pure_test_ecdsa_fe52_wnaf_result,
    pure_test_ecdsa_glv_product_x,
    pure_test_ecdsa_glv_result,
    pure_test_ecdsa_reference_product_x,
    pure_test_ecdsa_reference_result,
    pure_test_ecdsa_u_scalars,
    pure_test_ecdsa_wnaf_product_x,
    pure_test_ecdsa_wnaf_result,
    pure_test_fe52_add,
    pure_test_fe52_mul,
    pure_test_fe52_roundtrip,
    pure_test_fe52_sqr,
    pure_test_u256_add_mod,
    pure_test_u256_mul_field_fast,
    pure_test_u256_square_field,
    pure_verify_schnorr_bytes,
    pure_verify_taproot_tweak_precomputed,
)
from script_corpus_foundation import (
    CRYPTO_BACKEND_NATIVE,
    ascii_string_to_bytes,
    bytes_equal,
    CRYPTO_BACKEND_PURE,
    CryptoBackend,
    evaluate_bare_legacy_fixture,
    evaluate_bare_legacy_fixture_with_crypto,
    evaluate_bare_multisig_fixture,
    evaluate_bare_multisig_fixture_with_crypto,
    evaluate_p2pkh_fixture,
    evaluate_p2sh_fixture,
    evaluate_p2sh_fixture_with_crypto,
    evaluate_taproot_fixture,
    evaluate_taproot_fixture_diagnostic,
    evaluate_taproot_fixture_diagnostic_with_crypto,
    evaluate_p2pkh_fixture_with_crypto_timed,
    evaluate_witness_v0_fixture,
    evaluate_witness_v0_fixture_with_crypto,
    hex_text_to_bytes,
    is_bare_legacy_diagnostic_fixture,
    is_p2pkh_diagnostic_fixture,
    is_simple_p2sh_diagnostic_fixture,
    is_taproot_diagnostic_fixture,
    is_witness_v0_diagnostic_fixture,
    load_bare_multisig_fixture,
    taproot_tweak_hash,
)
from script_corpus_table import fixture_id_at, fixture_in_set, fixture_meta, script_fixture_count


def bool_json(value: Bool) -> String:
    if value:
        return String("true")
    return String("false")


def result_json(value: Bool) -> String:
    if value:
        return String("passed")
    return String("failed")


def passed_count_json(value: Bool) -> String:
    if value:
        return String("1")
    return String("0")


def failed_count_json(value: Bool) -> String:
    if value:
        return String("0")
    return String("1")


def diagnostic_failure_stage(message: String) -> String:
    if "unsupported crypto" in message or "crypto backend unsupported" in message:
        return String("unsupported_crypto")
    if "manifest" in message or "fixture id" in message or "fixture stem" in message or "hex" in message or "transaction parser" in message:
        return String("fixture_load")
    if "prevout" in message or "spent script" in message or "input index" in message or "scriptPubKey" in message:
        return String("prevout_shape")
    if "control block" in message or "leaf" in message or "witness script" in message or "witness control" in message:
        return String("control_block")
    if "Taproot tweak" in message or "tweak" in message:
        return String("taproot_tweak")
    if "SIGHASH" in message or "Taproot hash type" in message or "TapSighash" in message:
        return String("tapsighash")
    if "Schnorr" in message or "x-only" in message:
        return String("schnorr_verify")
    if "stack" in message or "opcode" in message or "OP_" in message or "conditional" in message:
        return String("opcode_execution")
    return String("fixture_evaluation")


def pure_shadow_fixture_enabled(fixture_id: String) -> Bool:
    # Keep pure-shadow corpus coverage operationally bounded. These rows prove
    # the injected pure backend through measured Taproot evaluators plus the
    # first P2PKH/ECDSA timing-gated probe.
    return (
        fixture_id == "scripts.p2pkh_sighash_single_38010"
        or fixture_id == "scripts.p2pkh_61174"
        or fixture_id == "scripts.p2pkh_107951"
        or fixture_id == "scripts.bare_legacy_118555"
        or fixture_id == "scripts.bare_multisig_27840"
        or fixture_id == "scripts.p2sh_cltv_38191"
        or fixture_id == "scripts.p2sh_add_51340"
        or fixture_id == "scripts.p2sh_3dup_63305"
        or fixture_id == "scripts.p2sh_2dup_63603"
        or fixture_id == "scripts.p2sh_82112"
        or fixture_id == "scripts.p2sh_82921"
        or fixture_id == "scripts.p2sh_sha1_82921"
        or fixture_id == "scripts.p2sh_108972"
        or fixture_id == "scripts.p2sh_116040"
        or fixture_id == "scripts.p2sh_abs_132361"
        or fixture_id == "scripts.p2wsh_op1_only_31842"
        or fixture_id == "scripts.p2wsh_cltv_32868"
        or fixture_id == "scripts.p2sh_p2wsh_op1_only_33500"
        or fixture_id == "scripts.p2wsh_size_lessthan_46779"
        or fixture_id == "scripts.p2wsh_2drop_54287"
        or fixture_id == "scripts.p2wsh_ifdup_csv_54297"
        or fixture_id == "scripts.p2wsh_mul_58173"
        or fixture_id == "scripts.p2wsh_rot_62754"
        or fixture_id == "scripts.p2wsh_altstack_66241"
        or fixture_id == "scripts.p2wsh_within_98025"
        or fixture_id == "scripts.p2wsh_98631"
        or fixture_id == "scripts.p2wsh_nip_98631"
        or fixture_id == "scripts.p2wsh_booland_136369"
        or fixture_id == "scripts.p2tr_tapscript_numequal_32712"
        or fixture_id == "scripts.p2tr_scriptpath_44295"
        or fixture_id == "scripts.p2tr_scriptpath_46599"
        or fixture_id == "scripts.p2tr_tapscript_sha256_52024"
        or fixture_id == "scripts.p2tr_tapscript_size_52497"
        or fixture_id == "scripts.p2tr_tapscript_hash256_67562"
        or fixture_id == "scripts.p2tr_tapscript_70924"
        or fixture_id == "scripts.p2tr_tapscript_71267"
        or fixture_id == "scripts.p2tr_tapscript_78841"
        or fixture_id == "scripts.p2tr_tapscript_82856"
        or fixture_id == "scripts.p2tr_tapscript_87214"
        or fixture_id == "scripts.p2tr_tapscript_89632"
        or fixture_id == "scripts.p2tr_tapscript_100372"
        or fixture_id == "scripts.p2tr_tapscript_108508"
        or fixture_id == "scripts.p2tr_tapscript_121035"
        or fixture_id == "scripts.p2tr_tapscript_126975"
        or fixture_id == "scripts.p2tr_tapscript_133634"
    )


def scripts_fixture_root(manifest_path: String) -> String:
    if manifest_path == "../Shared/conformance/fixtures/scripts/manifest.json":
        return String("../Shared/conformance/fixtures/scripts/")
    if manifest_path == "/workspace/Shared/conformance/fixtures/scripts/manifest.json":
        return String("/workspace/Shared/conformance/fixtures/scripts/")
    if manifest_path == "/workspace/Nodes/Shared/conformance/fixtures/scripts/manifest.json":
        return String("/workspace/Nodes/Shared/conformance/fixtures/scripts/")
    return String("../Shared/conformance/fixtures/scripts/")


def taproot_shadow_stem(fixture_id: String) raises -> String:
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return String("tx_p2tr_scriptpath_44295")
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return String("tx_p2tr_scriptpath_46599")
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return String("tx_p2tr_tapscript_100372")
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return String("tx_p2tr_tapscript_108508")
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return String("tx_p2tr_tapscript_121035")
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return String("tx_p2tr_tapscript_126975")
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return String("tx_p2tr_tapscript_133634")
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return String("tx_p2tr_tapscript_70924")
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return String("tx_p2tr_tapscript_71267")
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return String("tx_p2tr_tapscript_78841")
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return String("tx_p2tr_tapscript_82856")
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return String("tx_p2tr_tapscript_87214")
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return String("tx_p2tr_tapscript_89632")
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return String("tx_p2tr_tapscript_hash256_67562")
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return String("tx_p2tr_tapscript_numequal_32712")
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return String("tx_p2tr_tapscript_sha256_52024")
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return String("tx_p2tr_tapscript_size_52497")
    raise Error("unsupported Taproot shadow metrics fixture")


def taproot_shadow_witness_count(fixture_id: String) raises -> Int:
    if fixture_id == "scripts.p2tr_scriptpath_44295":
        return 3
    if fixture_id == "scripts.p2tr_scriptpath_46599":
        return 3
    if fixture_id == "scripts.p2tr_tapscript_100372":
        return 9
    if fixture_id == "scripts.p2tr_tapscript_108508":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_121035":
        return 552
    if fixture_id == "scripts.p2tr_tapscript_126975":
        return 538
    if fixture_id == "scripts.p2tr_tapscript_133634":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_70924":
        return 137
    if fixture_id == "scripts.p2tr_tapscript_71267":
        return 98
    if fixture_id == "scripts.p2tr_tapscript_78841":
        return 44
    if fixture_id == "scripts.p2tr_tapscript_82856":
        return 1
    if fixture_id == "scripts.p2tr_tapscript_87214":
        return 3
    if fixture_id == "scripts.p2tr_tapscript_89632":
        return 6
    if fixture_id == "scripts.p2tr_tapscript_hash256_67562":
        return 4
    if fixture_id == "scripts.p2tr_tapscript_numequal_32712":
        return 5
    if fixture_id == "scripts.p2tr_tapscript_sha256_52024":
        return 2
    if fixture_id == "scripts.p2tr_tapscript_size_52497":
        return 4
    raise Error("unsupported Taproot shadow witness fixture")


def file_byte_count(path: String) raises -> Int64:
    return Int64(len(Path(path).read_bytes()))


def taproot_shadow_tapscript_hex_bytes(manifest_path: String, fixture_id: String) raises -> Int64:
    var root = scripts_fixture_root(manifest_path)
    var stem = taproot_shadow_stem(fixture_id)
    return file_byte_count(root + fixture_id + String("/") + stem + String("_tapscript.hex"))


def taproot_shadow_witness_hex_bytes(manifest_path: String, fixture_id: String) raises -> Int64:
    var root = scripts_fixture_root(manifest_path)
    var stem = taproot_shadow_stem(fixture_id)
    var total = Int64(0)
    for i in range(taproot_shadow_witness_count(fixture_id)):
        total += file_byte_count(
            root + fixture_id + String("/") + stem + String("_witness_") + String(i) + String(".hex")
        )
    return total


def actual_json(code: Int32) -> String:
    if code == 0:
        return String("valid")
    if code == 1:
        return String("consensus_invalid")
    if code == 2:
        return String("malformed_input")
    return String("unknown")


def vector_id(index: Int) -> String:
    if index == 0:
        return String("ecdsa-valid-privkey-1-deadbeef")
    if index == 1:
        return String("ecdsa-consensus-invalid-wrong-message")
    if index == 2:
        return String("ecdsa-malformed-empty-pubkey")
    if index == 3:
        return String("schnorr-valid-privkey-12345-cafebabe")
    if index == 4:
        return String("schnorr-consensus-invalid-mutated-signature")
    if index == 5:
        return String("schnorr-malformed-zero-pubkey")
    if index == 6:
        return String("taproot-valid-privkey-300-c0ffee")
    return String("taproot-malformed-short-key")


def vector_operation(index: Int) -> String:
    if index < 3:
        return String("verify_ecdsa")
    if index < 6:
        return String("verify_schnorr")
    return String("taproot_tweak_xonly")


def expected_code(index: Int) -> Int32:
    if index == 0 or index == 3 or index == 6:
        return 0
    if index == 1 or index == 4:
        return 1
    return 2


def hex_string_to_bytes(text: String) raises -> List[UInt8]:
    return hex_text_to_bytes(ascii_string_to_bytes(text))


def vector_pubkey_hex(index: Int) -> String:
    if index == 0 or index == 1:
        return String("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    return String("")


def vector_xonly_hex(index: Int) -> String:
    if index == 3 or index == 4:
        return String("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f")
    if index == 5:
        return String("0000000000000000000000000000000000000000000000000000000000000000")
    if index == 6:
        return String("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05")
    if index == 7:
        return String("00")
    return String("")


def vector_msg_hash_hex(index: Int) -> String:
    if index == 0:
        return String("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5")
    if index == 1:
        return String("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    if index == 2 or index == 5:
        return String("0000000000000000000000000000000000000000000000000000000000000000")
    if index == 3 or index == 4:
        return String("3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9")
    return String("")


def vector_signature_hex(index: Int) -> String:
    if index == 0 or index == 1:
        return String("3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4")
    if index == 3:
        return String("632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b")
    if index == 4:
        return String("622f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b")
    return String("")


def vector_merkle_root_hex(index: Int) -> String:
    if index == 6:
        return String("446ba384864eb34196e08044029fb463d97748e4549dfd0e2612f60d74c4f165")
    return String("")


def vector_expected_xonly_hex(index: Int) -> String:
    if index == 6:
        return String("4b3e30f94e0ae82945cbb40d83088b8f3bea370c24c575b7788889ad5e64da8b")
    return String("")


def vector_expected_parity(index: Int) -> Int:
    if index == 6:
        return 1
    return -1


def native_vector_actual(shim_path: String, index: Int) raises -> Int32:
    var native = OwnedDLHandle(shim_path)
    if vector_operation(index) == "verify_ecdsa":
        var pubkey = hex_string_to_bytes(vector_pubkey_hex(index))
        var sig = hex_string_to_bytes(vector_signature_hex(index))
        var msg = hex_string_to_bytes(vector_msg_hash_hex(index))
        var pubkey_alloc_len = len(pubkey)
        if pubkey_alloc_len == 0:
            pubkey_alloc_len = 1
        var sig_alloc_len = len(sig)
        if sig_alloc_len == 0:
            sig_alloc_len = 1
        var msg_alloc_len = len(msg)
        if msg_alloc_len == 0:
            msg_alloc_len = 1
        var pubkey_ptr = alloc[UInt8](pubkey_alloc_len)
        var sig_ptr = alloc[UInt8](sig_alloc_len)
        var msg_ptr = alloc[UInt8](msg_alloc_len)
        for i in range(len(pubkey)):
            pubkey_ptr[i] = pubkey[i]
        for i in range(len(sig)):
            sig_ptr[i] = sig[i]
        for i in range(len(msg)):
            msg_ptr[i] = msg[i]
        var result = native.call["mojobitnode_verify_ecdsa_der_bytes_len", Int32](
            pubkey_ptr,
            Int32(len(pubkey)),
            sig_ptr,
            Int32(len(sig)),
            msg_ptr,
            Int32(len(msg)),
        )
        pubkey_ptr.free()
        sig_ptr.free()
        msg_ptr.free()
        return result
    if vector_operation(index) == "verify_schnorr":
        var xonly = hex_string_to_bytes(vector_xonly_hex(index))
        var sig = hex_string_to_bytes(vector_signature_hex(index))
        var msg = hex_string_to_bytes(vector_msg_hash_hex(index))
        var xonly_alloc_len = len(xonly)
        if xonly_alloc_len == 0:
            xonly_alloc_len = 1
        var sig_alloc_len = len(sig)
        if sig_alloc_len == 0:
            sig_alloc_len = 1
        var msg_alloc_len = len(msg)
        if msg_alloc_len == 0:
            msg_alloc_len = 1
        var xonly_ptr = alloc[UInt8](xonly_alloc_len)
        var sig_ptr = alloc[UInt8](sig_alloc_len)
        var msg_ptr = alloc[UInt8](msg_alloc_len)
        for i in range(len(xonly)):
            xonly_ptr[i] = xonly[i]
        for i in range(len(sig)):
            sig_ptr[i] = sig[i]
        for i in range(len(msg)):
            msg_ptr[i] = msg[i]
        var result = native.call["mojobitnode_verify_schnorr_bytes_len", Int32](
            xonly_ptr,
            Int32(len(xonly)),
            sig_ptr,
            Int32(len(sig)),
            msg_ptr,
            Int32(len(msg)),
        )
        xonly_ptr.free()
        sig_ptr.free()
        msg_ptr.free()
        return result
    var internal = hex_string_to_bytes(vector_xonly_hex(index))
    var merkle_root = hex_string_to_bytes(vector_merkle_root_hex(index))
    var expected = hex_string_to_bytes(vector_expected_xonly_hex(index))
    var tweak = List[UInt8]()
    if index == 7:
        for _ in range(32):
            tweak.append(UInt8(0))
    else:
        tweak = taproot_tweak_hash(internal, merkle_root)
    var internal_alloc_len = len(internal)
    if internal_alloc_len == 0:
        internal_alloc_len = 1
    var tweak_alloc_len = len(tweak)
    if tweak_alloc_len == 0:
        tweak_alloc_len = 1
    var expected_alloc_len = len(expected)
    if expected_alloc_len == 0:
        expected_alloc_len = 1
    var internal_ptr = alloc[UInt8](internal_alloc_len)
    var tweak_ptr = alloc[UInt8](tweak_alloc_len)
    var expected_ptr = alloc[UInt8](expected_alloc_len)
    for i in range(len(internal)):
        internal_ptr[i] = internal[i]
    for i in range(len(tweak)):
        tweak_ptr[i] = tweak[i]
    for i in range(len(expected)):
        expected_ptr[i] = expected[i]
    var result = native.call["mojobitnode_verify_taproot_tweak_precomputed_bytes_len", Int32](
        internal_ptr,
        Int32(len(internal)),
        tweak_ptr,
        Int32(len(tweak)),
        expected_ptr,
        Int32(len(expected)),
        Int32(vector_expected_parity(index)),
    )
    internal_ptr.free()
    tweak_ptr.free()
    expected_ptr.free()
    return result


def pure_crypto_profile_json(shim_path: String, surface: String) raises -> String:
    var clock = Native(shim_path)
    var total_started = clock.now_ms()
    var pubkey = hex_string_to_bytes(vector_pubkey_hex(0))
    var sig = hex_string_to_bytes(vector_signature_hex(0))
    var msg = hex_string_to_bytes(vector_msg_hash_hex(0))

    var started = clock.now_ms()
    var parsed_der = pure_test_ecdsa_parse_der(sig)
    var der_parse_ms = clock.now_ms() - started

    started = clock.now_ms()
    var parsed_pubkey = pure_test_ecdsa_parse_pubkey_x(pubkey)
    var pubkey_parse_ms = clock.now_ms() - started

    started = clock.now_ms()
    var normalized_s = pure_test_ecdsa_normalized_s(sig)
    var high_s_normalize_ms = clock.now_ms() - started

    started = clock.now_ms()
    var inverse_s = pure_test_ecdsa_inverse_s(sig)
    var scalar_inverse_ms = clock.now_ms() - started

    started = clock.now_ms()
    var u_scalars = pure_test_ecdsa_u_scalars(sig, msg)
    var scalar_multiplications_ms = clock.now_ms() - started

    started = clock.now_ms()
    var reference_x = pure_test_ecdsa_reference_product_x(pubkey, sig, msg)
    var reference_double_base_ms = clock.now_ms() - started

    started = clock.now_ms()
    var wnaf_x = pure_test_ecdsa_wnaf_product_x(pubkey, sig, msg)
    var wnaf_double_base_ms = clock.now_ms() - started

    started = clock.now_ms()
    var wnaf_result = pure_test_ecdsa_wnaf_result(pubkey, sig, msg)
    var affine_and_result_ms = clock.now_ms() - started

    started = clock.now_ms()
    var glv_x = pure_test_ecdsa_glv_product_x(pubkey, sig, msg)
    var glv_double_base_ms = clock.now_ms() - started

    started = clock.now_ms()
    var glv_result = pure_test_ecdsa_glv_result(pubkey, sig, msg)
    var glv_affine_and_result_ms = clock.now_ms() - started

    started = clock.now_ms()
    var reference_result = pure_test_ecdsa_reference_result(pubkey, sig, msg)
    var reference_result_ms = clock.now_ms() - started

    started = clock.now_ms()
    var native_result = native_vector_actual(shim_path, 0)
    var native_compare_ms = clock.now_ms() - started

    var wnaf_matches_reference = bytes_equal(wnaf_x, reference_x) and wnaf_result == reference_result
    var glv_matches_wnaf = bytes_equal(glv_x, wnaf_x) and glv_result == wnaf_result
    var matches_native = glv_result == native_result
    var result = String("diagnostic")
    if not wnaf_matches_reference or not glv_matches_wnaf or not matches_native:
        result = String("failed")

    var total_ms = clock.now_ms() - total_started
    return (
        String('{"schema":"port.pure_crypto_profile.v1","category":"pure_crypto_profile",')
        + String('"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","runtime_surface":"')
        + surface
        + String('","entrypoint_language":"mojo","native_crypto_backend":"libsecp256k1",')
        + String('"shadow_crypto_backend":"mojo-pure-secp256k1","native_shim":"owned_c",')
        + String('"target_vector":"ecdsa-valid-privkey-1-deadbeef","operation":"verify_ecdsa",')
        + String('"stage_ms":{"der_parse":')
        + String(der_parse_ms)
        + String(',"pubkey_parse_lift":')
        + String(pubkey_parse_ms)
        + String(',"high_s_normalization":')
        + String(high_s_normalize_ms)
        + String(',"scalar_inverse":')
        + String(scalar_inverse_ms)
        + String(',"scalar_multiplications":')
        + String(scalar_multiplications_ms)
        + String(',"reference_double_base_plus_affine":')
        + String(reference_double_base_ms)
        + String(',"wnaf_double_base_plus_affine":')
        + String(wnaf_double_base_ms)
        + String(',"wnaf_affine_result":')
        + String(affine_and_result_ms)
        + String(',"glv_double_base_plus_affine":')
        + String(glv_double_base_ms)
        + String(',"glv_affine_result":')
        + String(glv_affine_and_result_ms)
        + String(',"reference_result":')
        + String(reference_result_ms)
        + String(',"native_result_compare":')
        + String(native_compare_ms)
        + String('},"bytes":{"parsed_der":')
        + String(len(parsed_der))
        + String(',"parsed_pubkey_x":')
        + String(len(parsed_pubkey))
        + String(',"normalized_s":')
        + String(len(normalized_s))
        + String(',"inverse_s":')
        + String(len(inverse_s))
        + String(',"u_scalars":')
        + String(len(u_scalars))
        + String('},"reference_result_code":')
        + String(reference_result)
        + String(',"wnaf_result_code":')
        + String(wnaf_result)
        + String(',"glv_result_code":')
        + String(glv_result)
        + String(',"native_result_code":')
        + String(native_result)
        + String(',"wnaf_matches_reference":')
        + bool_json(wnaf_matches_reference)
        + String(',"glv_matches_wnaf":')
        + bool_json(glv_matches_wnaf)
        + String(',"glv_matches_native":')
        + bool_json(matches_native)
        + String(',"total_ms":')
        + String(total_ms)
        + String(',"p2pkh_shadow_gate_ms":1000,"result":"')
        + result
        + String('"}')
    )


def per_iteration_us(total_ms: Int64, iterations: Int) -> Int64:
    return (total_ms * Int64(1000)) // Int64(iterations)


def pure_crypto_microbench_json(
    shim_path: String,
    surface: String,
    iterations: Int,
    bench_case: String,
    native_compare: Bool,
) raises -> String:
    var clock = Native(shim_path)
    var total_started = clock.now_ms()
    var run_ecdsa = bench_case == "all" or bench_case == "ecdsa"
    var run_schnorr = bench_case == "all" or bench_case == "schnorr"
    var run_taproot = bench_case == "all" or bench_case == "taproot"
    var run_field = bench_case == "all" or bench_case == "field"
    var run_point = bench_case == "all" or bench_case == "point"
    var result = String("diagnostic")
    var loop_iterations = iterations
    if loop_iterations <= 0:
        loop_iterations = 1000

    var ecdsa_pubkey = hex_string_to_bytes(vector_pubkey_hex(0))
    var ecdsa_sig = hex_string_to_bytes(vector_signature_hex(0))
    var ecdsa_msg = hex_string_to_bytes(vector_msg_hash_hex(0))
    var schnorr_pubkey = hex_string_to_bytes(vector_xonly_hex(3))
    var schnorr_sig = hex_string_to_bytes(vector_signature_hex(3))
    var schnorr_msg = hex_string_to_bytes(vector_msg_hash_hex(3))
    var taproot_internal = hex_string_to_bytes(vector_xonly_hex(6))
    var taproot_merkle_root = hex_string_to_bytes(vector_merkle_root_hex(6))
    var taproot_tweak = taproot_tweak_hash(taproot_internal, taproot_merkle_root)
    var taproot_expected = hex_string_to_bytes(vector_expected_xonly_hex(6))
    var taproot_parity = vector_expected_parity(6)
    var field_p = hex_string_to_bytes(String("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"))
    var field_a = hex_string_to_bytes(String("f73dafc19d228263cb4ed5db0500e47f603b61fa65eeae217ccb74acc1d36143"))
    var field_b = hex_string_to_bytes(String("6114c8de454c9b5272e1284cd8f2974118b8b15da4f2439136e5d08b7eb03b7b"))
    var field_one = hex_string_to_bytes(String("0000000000000000000000000000000000000000000000000000000000000001"))

    var ecdsa_der_parse_ms = Int64(0)
    var ecdsa_pubkey_parse_lift_ms = Int64(0)
    var ecdsa_high_s_ms = Int64(0)
    var ecdsa_scalar_inverse_ms = Int64(0)
    var ecdsa_u_scalar_ms = Int64(0)
    var ecdsa_wnaf_product_ms = Int64(0)
    var ecdsa_glv_product_ms = Int64(0)
    var ecdsa_glv_result_ms = Int64(0)
    var ecdsa_fe52_wnaf_product_ms = Int64(0)
    var ecdsa_fe52_wnaf_result_ms = Int64(0)
    var ecdsa_fe52_glv_product_ms = Int64(0)
    var ecdsa_fe52_glv_result_ms = Int64(0)
    var ecdsa_wnaf_valid = 0
    var ecdsa_glv_valid = 0
    var ecdsa_fe52_wnaf_valid = 0
    var ecdsa_fe52_wnaf_result_valid = 0
    var ecdsa_fe52_glv_valid = 0
    var ecdsa_glv_wnaf_mismatches = 0
    var ecdsa_fe52_mismatches = 0
    var ecdsa_native_compare_ms = Int64(0)
    var ecdsa_native_result = Int32(-1)

    var schnorr_verify_ms = Int64(0)
    var schnorr_valid = 0
    var schnorr_invalid = 0
    var schnorr_malformed = 0
    var schnorr_native_compare_ms = Int64(0)
    var schnorr_native_result = Int32(-1)

    var taproot_verify_ms = Int64(0)
    var taproot_valid = 0
    var taproot_invalid = 0
    var taproot_malformed = 0
    var taproot_native_compare_ms = Int64(0)
    var taproot_native_result = Int32(-1)

    var field_4x64_add_ms = Int64(0)
    var field_4x64_mul_ms = Int64(0)
    var field_4x64_sqr_ms = Int64(0)
    var field_4x64_normalize_ms = Int64(0)
    var field_fe52_add_ms = Int64(0)
    var field_fe52_mul_ms = Int64(0)
    var field_fe52_sqr_ms = Int64(0)
    var field_fe52_normalize_ms = Int64(0)
    var field_iterations = 0
    var field_mismatches = 0
    var point_4x64_double_base_ms = Int64(0)
    var point_fe52_double_base_ms = Int64(0)
    var point_iterations = 0
    var point_mismatches = 0

    if run_field:
        var expected_add = pure_test_u256_add_mod(field_a, field_b, field_p)
        var expected_mul = pure_test_u256_mul_field_fast(field_a, field_b)
        var expected_sqr = pure_test_u256_square_field(field_a)
        var expected_norm = pure_test_u256_mul_field_fast(field_a, field_one)

        var started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_u256_add_mod(field_a, field_b, field_p)
            if bytes_equal(actual, expected_add):
                field_iterations += 1
        field_4x64_add_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_u256_mul_field_fast(field_a, field_b)
            if not bytes_equal(actual, expected_mul):
                field_mismatches += 1
        field_4x64_mul_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_u256_square_field(field_a)
            if not bytes_equal(actual, expected_sqr):
                field_mismatches += 1
        field_4x64_sqr_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_u256_mul_field_fast(field_a, field_one)
            if not bytes_equal(actual, expected_norm):
                field_mismatches += 1
        field_4x64_normalize_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_fe52_add(field_a, field_b)
            if not bytes_equal(actual, expected_add):
                field_mismatches += 1
        field_fe52_add_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_fe52_mul(field_a, field_b)
            if not bytes_equal(actual, expected_mul):
                field_mismatches += 1
        field_fe52_mul_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_fe52_sqr(field_a)
            if not bytes_equal(actual, expected_sqr):
                field_mismatches += 1
        field_fe52_sqr_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_fe52_roundtrip(field_a)
            if not bytes_equal(actual, expected_norm):
                field_mismatches += 1
        field_fe52_normalize_ms = clock.now_ms() - started

    if run_point:
        var expected_reference_x = pure_test_ecdsa_reference_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
        var started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_ecdsa_reference_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if bytes_equal(actual, expected_reference_x):
                point_iterations += 1
            else:
                point_mismatches += 1
        point_4x64_double_base_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var actual = pure_test_ecdsa_fe52_reference_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if not bytes_equal(actual, expected_reference_x):
                point_mismatches += 1
        point_fe52_double_base_ms = clock.now_ms() - started

    if run_ecdsa:
        var expected_wnaf_x = pure_test_ecdsa_wnaf_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
        var expected_wnaf_result = pure_test_ecdsa_wnaf_result(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)

        var started = clock.now_ms()
        for _ in range(loop_iterations):
            _ = pure_test_ecdsa_parse_der(ecdsa_sig)
        ecdsa_der_parse_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            _ = pure_test_ecdsa_parse_pubkey_x(ecdsa_pubkey)
        ecdsa_pubkey_parse_lift_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            _ = pure_test_ecdsa_normalized_s(ecdsa_sig)
        ecdsa_high_s_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            _ = pure_test_ecdsa_inverse_s(ecdsa_sig)
        ecdsa_scalar_inverse_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            _ = pure_test_ecdsa_u_scalars(ecdsa_sig, ecdsa_msg)
        ecdsa_u_scalar_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var wnaf_x = pure_test_ecdsa_wnaf_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if bytes_equal(wnaf_x, expected_wnaf_x):
                ecdsa_wnaf_valid += 1
        ecdsa_wnaf_product_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var glv_x = pure_test_ecdsa_glv_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if not bytes_equal(glv_x, expected_wnaf_x):
                ecdsa_glv_wnaf_mismatches += 1
        ecdsa_glv_product_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var glv_result = pure_test_ecdsa_glv_result(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if glv_result == expected_wnaf_result:
                ecdsa_glv_valid += 1
            else:
                ecdsa_glv_wnaf_mismatches += 1
        ecdsa_glv_result_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var fe52_wnaf_x = pure_test_ecdsa_fe52_wnaf_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if bytes_equal(fe52_wnaf_x, expected_wnaf_x):
                ecdsa_fe52_wnaf_valid += 1
            else:
                ecdsa_fe52_mismatches += 1
        ecdsa_fe52_wnaf_product_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var fe52_wnaf_result = pure_test_ecdsa_fe52_wnaf_result(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if fe52_wnaf_result == expected_wnaf_result:
                ecdsa_fe52_wnaf_result_valid += 1
            else:
                ecdsa_fe52_mismatches += 1
        ecdsa_fe52_wnaf_result_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var fe52_glv_x = pure_test_ecdsa_fe52_glv_product_x(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if not bytes_equal(fe52_glv_x, expected_wnaf_x):
                ecdsa_fe52_mismatches += 1
        ecdsa_fe52_glv_product_ms = clock.now_ms() - started

        started = clock.now_ms()
        for _ in range(loop_iterations):
            var fe52_glv_result = pure_test_ecdsa_fe52_glv_result(ecdsa_pubkey, ecdsa_sig, ecdsa_msg)
            if fe52_glv_result == expected_wnaf_result:
                ecdsa_fe52_glv_valid += 1
            else:
                ecdsa_fe52_mismatches += 1
        ecdsa_fe52_glv_result_ms = clock.now_ms() - started

        if native_compare:
            started = clock.now_ms()
            ecdsa_native_result = native_vector_actual(shim_path, 0)
            ecdsa_native_compare_ms = clock.now_ms() - started
            if ecdsa_native_result != expected_wnaf_result:
                result = String("failed")

    if run_schnorr:
        var started = clock.now_ms()
        for _ in range(loop_iterations):
            var schnorr_result = pure_verify_schnorr_bytes(schnorr_pubkey, schnorr_sig, schnorr_msg)
            if schnorr_result == Int32(0):
                schnorr_valid += 1
            elif schnorr_result == Int32(1):
                schnorr_invalid += 1
            elif schnorr_result == Int32(2):
                schnorr_malformed += 1
        schnorr_verify_ms = clock.now_ms() - started

        if native_compare:
            started = clock.now_ms()
            schnorr_native_result = native_vector_actual(shim_path, 3)
            schnorr_native_compare_ms = clock.now_ms() - started
            if schnorr_native_result != Int32(0):
                result = String("failed")

    if run_taproot:
        var started = clock.now_ms()
        for _ in range(loop_iterations):
            var taproot_result = pure_verify_taproot_tweak_precomputed(
                taproot_internal,
                taproot_tweak,
                taproot_expected,
                taproot_parity,
            )
            if taproot_result == Int32(0):
                taproot_valid += 1
            elif taproot_result == Int32(1):
                taproot_invalid += 1
            elif taproot_result == Int32(2):
                taproot_malformed += 1
        taproot_verify_ms = clock.now_ms() - started

        if native_compare:
            started = clock.now_ms()
            taproot_native_result = native_vector_actual(shim_path, 6)
            taproot_native_compare_ms = clock.now_ms() - started
            if taproot_native_result != Int32(0):
                result = String("failed")

    if ecdsa_glv_wnaf_mismatches != 0:
        result = String("failed")
    if ecdsa_fe52_mismatches != 0:
        result = String("failed")
    if run_ecdsa and (ecdsa_wnaf_valid != loop_iterations or ecdsa_glv_valid != loop_iterations):
        result = String("failed")
    if run_ecdsa and (ecdsa_fe52_wnaf_valid != loop_iterations or ecdsa_fe52_wnaf_result_valid != loop_iterations or ecdsa_fe52_glv_valid != loop_iterations):
        result = String("failed")
    if run_schnorr and schnorr_valid != loop_iterations:
        result = String("failed")
    if run_taproot and taproot_valid != loop_iterations:
        result = String("failed")
    if run_field and (field_iterations != loop_iterations or field_mismatches != 0):
        result = String("failed")
    if run_point and (point_iterations != loop_iterations or point_mismatches != 0):
        result = String("failed")

    var total_ms = clock.now_ms() - total_started
    return (
        String('{"schema":"port.pure_crypto_microbench.v1","category":"pure_crypto_microbench",')
        + String('"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","runtime_surface":"')
        + surface
        + String('","entrypoint_language":"mojo","native_crypto_backend":"libsecp256k1",')
        + String('"shadow_crypto_backend":"mojo-pure-secp256k1","native_shim":"owned_c",')
        + String('"diagnostic_only":true,"selected_case":"')
        + bench_case
        + String('","iterations":')
        + String(loop_iterations)
        + String(',"native_compare_enabled":')
        + bool_json(native_compare)
        + String(',"total_ms":')
        + String(total_ms)
        + String(',"ecdsa":{"enabled":')
        + bool_json(run_ecdsa)
        + String(',"iterations":')
        + String(loop_iterations)
        + String(',"stage_ms":{"der_parse":')
        + String(ecdsa_der_parse_ms)
        + String(',"pubkey_parse_lift":')
        + String(ecdsa_pubkey_parse_lift_ms)
        + String(',"high_s_normalization":')
        + String(ecdsa_high_s_ms)
        + String(',"scalar_inverse":')
        + String(ecdsa_scalar_inverse_ms)
        + String(',"scalar_multiplications":')
        + String(ecdsa_u_scalar_ms)
        + String(',"wnaf_product":')
        + String(ecdsa_wnaf_product_ms)
        + String(',"glv_product":')
        + String(ecdsa_glv_product_ms)
        + String(',"glv_result":')
        + String(ecdsa_glv_result_ms)
        + String(',"fe52_wnaf_product":')
        + String(ecdsa_fe52_wnaf_product_ms)
        + String(',"fe52_wnaf_result":')
        + String(ecdsa_fe52_wnaf_result_ms)
        + String(',"fe52_glv_product":')
        + String(ecdsa_fe52_glv_product_ms)
        + String(',"fe52_glv_result":')
        + String(ecdsa_fe52_glv_result_ms)
        + String(',"native_compare":')
        + String(ecdsa_native_compare_ms)
        + String('},"per_iteration_us":{"der_parse":')
        + String(per_iteration_us(ecdsa_der_parse_ms, loop_iterations))
        + String(',"pubkey_parse_lift":')
        + String(per_iteration_us(ecdsa_pubkey_parse_lift_ms, loop_iterations))
        + String(',"high_s_normalization":')
        + String(per_iteration_us(ecdsa_high_s_ms, loop_iterations))
        + String(',"scalar_inverse":')
        + String(per_iteration_us(ecdsa_scalar_inverse_ms, loop_iterations))
        + String(',"scalar_multiplications":')
        + String(per_iteration_us(ecdsa_u_scalar_ms, loop_iterations))
        + String(',"wnaf_product":')
        + String(per_iteration_us(ecdsa_wnaf_product_ms, loop_iterations))
        + String(',"glv_product":')
        + String(per_iteration_us(ecdsa_glv_product_ms, loop_iterations))
        + String(',"glv_result":')
        + String(per_iteration_us(ecdsa_glv_result_ms, loop_iterations))
        + String(',"fe52_wnaf_product":')
        + String(per_iteration_us(ecdsa_fe52_wnaf_product_ms, loop_iterations))
        + String(',"fe52_wnaf_result":')
        + String(per_iteration_us(ecdsa_fe52_wnaf_result_ms, loop_iterations))
        + String(',"fe52_glv_product":')
        + String(per_iteration_us(ecdsa_fe52_glv_product_ms, loop_iterations))
        + String(',"fe52_glv_result":')
        + String(per_iteration_us(ecdsa_fe52_glv_result_ms, loop_iterations))
        + String('},"wnaf_valid_count":')
        + String(ecdsa_wnaf_valid)
        + String(',"glv_valid_count":')
        + String(ecdsa_glv_valid)
        + String(',"fe52_wnaf_valid_count":')
        + String(ecdsa_fe52_wnaf_valid)
        + String(',"fe52_wnaf_result_valid_count":')
        + String(ecdsa_fe52_wnaf_result_valid)
        + String(',"fe52_glv_valid_count":')
        + String(ecdsa_fe52_glv_valid)
        + String(',"glv_wnaf_mismatches":')
        + String(ecdsa_glv_wnaf_mismatches)
        + String(',"fe52_mismatches":')
        + String(ecdsa_fe52_mismatches)
        + String(',"native_result_code":')
        + String(ecdsa_native_result)
        + String('},"field":{"enabled":')
        + bool_json(run_field)
        + String(',"iterations":')
        + String(loop_iterations)
        + String(',"reference_4x64":{"stage_ms":{"add":')
        + String(field_4x64_add_ms)
        + String(',"mul":')
        + String(field_4x64_mul_ms)
        + String(',"sqr":')
        + String(field_4x64_sqr_ms)
        + String(',"normalize":')
        + String(field_4x64_normalize_ms)
        + String('},"per_iteration_us":{"add":')
        + String(per_iteration_us(field_4x64_add_ms, loop_iterations))
        + String(',"mul":')
        + String(per_iteration_us(field_4x64_mul_ms, loop_iterations))
        + String(',"sqr":')
        + String(per_iteration_us(field_4x64_sqr_ms, loop_iterations))
        + String(',"normalize":')
        + String(per_iteration_us(field_4x64_normalize_ms, loop_iterations))
        + String('}},"fe52":{"stage_ms":{"add":')
        + String(field_fe52_add_ms)
        + String(',"mul":')
        + String(field_fe52_mul_ms)
        + String(',"sqr":')
        + String(field_fe52_sqr_ms)
        + String(',"normalize":')
        + String(field_fe52_normalize_ms)
        + String('},"per_iteration_us":{"add":')
        + String(per_iteration_us(field_fe52_add_ms, loop_iterations))
        + String(',"mul":')
        + String(per_iteration_us(field_fe52_mul_ms, loop_iterations))
        + String(',"sqr":')
        + String(per_iteration_us(field_fe52_sqr_ms, loop_iterations))
        + String(',"normalize":')
        + String(per_iteration_us(field_fe52_normalize_ms, loop_iterations))
        + String('}},"parity_iterations":')
        + String(field_iterations)
        + String(',"mismatches":')
        + String(field_mismatches)
        + String('},"point":{"enabled":')
        + bool_json(run_point)
        + String(',"iterations":')
        + String(loop_iterations)
        + String(',"reference_4x64":{"double_base_ms":')
        + String(point_4x64_double_base_ms)
        + String(',"double_base_per_iteration_us":')
        + String(per_iteration_us(point_4x64_double_base_ms, loop_iterations))
        + String('},"fe52":{"double_base_ms":')
        + String(point_fe52_double_base_ms)
        + String(',"double_base_per_iteration_us":')
        + String(per_iteration_us(point_fe52_double_base_ms, loop_iterations))
        + String('},"parity_iterations":')
        + String(point_iterations)
        + String(',"mismatches":')
        + String(point_mismatches)
        + String('},"schnorr":{"enabled":')
        + bool_json(run_schnorr)
        + String(',"iterations":')
        + String(loop_iterations)
        + String(',"verify_ms":')
        + String(schnorr_verify_ms)
        + String(',"verify_per_iteration_us":')
        + String(per_iteration_us(schnorr_verify_ms, loop_iterations))
        + String(',"valid_count":')
        + String(schnorr_valid)
        + String(',"invalid_count":')
        + String(schnorr_invalid)
        + String(',"malformed_count":')
        + String(schnorr_malformed)
        + String(',"native_compare_ms":')
        + String(schnorr_native_compare_ms)
        + String(',"native_result_code":')
        + String(schnorr_native_result)
        + String('},"taproot":{"enabled":')
        + bool_json(run_taproot)
        + String(',"iterations":')
        + String(loop_iterations)
        + String(',"verify_ms":')
        + String(taproot_verify_ms)
        + String(',"verify_per_iteration_us":')
        + String(per_iteration_us(taproot_verify_ms, loop_iterations))
        + String(',"valid_count":')
        + String(taproot_valid)
        + String(',"invalid_count":')
        + String(taproot_invalid)
        + String(',"malformed_count":')
        + String(taproot_malformed)
        + String(',"native_compare_ms":')
        + String(taproot_native_compare_ms)
        + String(',"native_result_code":')
        + String(taproot_native_result)
        + String('},"result":"')
        + result
        + String('"}')
    )


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: mojobitnode <status|native-crypto-vectors|pure-crypto-profile|pure-crypto-microbench|storage-proof|script-corpus|script-corpus-dev|local-reference-proof> [options]")
        return

    var command = String(args[1])
    var surface = getenv("MOJOBITNODE_RUNTIME_SURFACE", "host")
    var shim_path = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var datadir = String("./data-mojo")
    var result_path = String("")
    var vectors_path = String("../Shared/conformance/fixtures/native_crypto_v1_vectors.json")
    var manifest_path = String("../Shared/conformance/fixtures/scripts/manifest.json")
    var fixture_id = String("")
    var fixture_set = String("all")
    var shadow_crypto = False
    var microbench_iterations = 1000
    var microbench_case = String("all")
    var native_compare = False
    var peer = getenv("REFERENCE_P2P_PEER", "127.0.0.1:48333")
    var target = 5000
    var progress = 500
    for i in range(len(args)):
        if args[i] == "--datadir" and i + 1 < len(args):
            datadir = String(args[i + 1])
        if args[i] == "--result-path" and i + 1 < len(args):
            result_path = String(args[i + 1])
        if args[i] == "--vectors" and i + 1 < len(args):
            vectors_path = String(args[i + 1])
        if args[i] == "--manifest" and i + 1 < len(args):
            manifest_path = String(args[i + 1])
        if args[i] == "--fixture-id" and i + 1 < len(args):
            fixture_id = String(args[i + 1])
        if args[i] == "--fixture-set" and i + 1 < len(args):
            fixture_set = String(args[i + 1])
        if args[i] == "--shadow-crypto":
            shadow_crypto = True
        if args[i] == "--native-compare":
            native_compare = True
        if args[i] == "--iterations" and i + 1 < len(args):
            microbench_iterations = Int(String(args[i + 1]))
        if args[i] == "--case" and i + 1 < len(args):
            microbench_case = String(args[i + 1])
        if args[i] == "--peer" and i + 1 < len(args):
            peer = String(args[i + 1])
        if args[i] == "--target" and i + 1 < len(args):
            target = Int(String(args[i + 1]))
        if args[i] == "--progress" and i + 1 < len(args):
            progress = Int(String(args[i + 1]))

    if command == "status":
        var native = OwnedDLHandle(shim_path)
        var crypto_available = native.call["mojobitnode_native_crypto_available", Int32]() == 1
        var json = (
            String('{"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","chain":"testnet4",')
            + String('"runtime_surface":"')
            + surface
            + String('","entrypoint_language":"mojo","native_shim":"owned_c",')
            + String('"sync_status":"spike_not_started","binary_gate_status":"not_attempted",')
            + String('"header_height":0,"stored_block_height":0,"validated_height":0,"validated_hash":"",')
            + String('"chainstate_backend":"rocksdb","runtime_truth_backend":"rocksdb","rocksdb_runtime_truth":true,')
            + String('"chainstate_status":"spike_not_initialized","datadir":"')
            + datadir
            + String('","native_crypto_backend":"libsecp256k1","native_crypto_available":')
            + bool_json(crypto_available)
            + String(',"current_blocker":null,"last_error":""}')
        )
        print(json)
        return

    if command == "native-crypto-vectors":
        var case_total = 8
        var passed_count = 0
        var results = String("")
        for i in range(case_total):
            var actual_code = native_vector_actual(shim_path, i)
            var expected = expected_code(i)
            var passed = actual_code == expected
            if passed:
                passed_count += 1
            if i != 0:
                results += String(",")
            results += (
                String('{"id":"')
                + vector_id(i)
                + String('","operation":"')
                + vector_operation(i)
                + String('","expected":"')
                + actual_json(expected)
                + String('","actual":"')
                + actual_json(actual_code)
                + String('","status":"')
                + result_json(passed)
                + String('"}')
            )
        var passed = passed_count == Int(case_total)
        var json = (
            String('{"schema":"port.native_crypto_vectors.v1","implementation":"Mojo",')
            + String('"port":"mojo","node_id":"mojobitnode","runtime_surface":"')
            + surface
            + String('","entrypoint_language":"mojo","native_shim":"owned_c",')
            + String('"backend":"libsecp256k1","delegated":false,"fixture_path":"')
            + vectors_path
            + String('","case_total":')
            + String(case_total)
            + String(',"case_passed":')
            + String(passed_count)
            + String(',"result":"')
            + result_json(passed)
            + String('","results":[')
            + results
            + String("]}")
        )
        print(json)
        if result_path != "":
            var writer = OwnedDLHandle(shim_path)
            _ = writer.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        return

    if command == "script-corpus-dev" or command == "script-corpus":
        var verifier_engine = String("mojo_dev_foundation")
        if command == "script-corpus":
            fixture_id = String("")
            fixture_set = String("all")
            verifier_engine = String("mojo_native")
        if command == "script-corpus-dev":
            shadow_crypto = False
        if fixture_id != "":
            _ = fixture_meta(fixture_id)
        var passed_count = 0
        var failed_count = 0
        var fixture_count = 0
        var shadow_supported_count = 0
        var shadow_agreed_count = 0
        var shadow_disagreement_count = 0
        var shadow_eval_ms = Int64(0)
        var shadow_supported_eval_ms = Int64(0)
        var shadow_max_row_ms = Int64(0)
        var shadow_largest_duration_fixture = String("")
        var shadow_largest_tapscript_fixture = String("")
        var shadow_largest_tapscript_hex_bytes = Int64(0)
        var results = String("")
        var shadow_clock = Native(shim_path)
        for i in range(script_fixture_count()):
            var current_id = fixture_id_at(i)
            if fixture_id != "" and current_id != fixture_id:
                continue
            if fixture_id == "" and not fixture_in_set(current_id, fixture_set):
                continue
            var meta = fixture_meta(current_id)
            var eval_id = String(meta.fixture_id)
            var current_passed = False
            var failure = String("")
            var failure_stage = String("")
            try:
                if eval_id == "scripts.bare_multisig_27840":
                    var fixture = load_bare_multisig_fixture(manifest_path)
                    current_passed = evaluate_bare_multisig_fixture(fixture, shim_path)
                    if not current_passed:
                        failure_stage = String("opcode_execution")
                        failure = String("bare multisig script terminal result was false")
                elif is_simple_p2sh_diagnostic_fixture(eval_id):
                    current_passed = evaluate_p2sh_fixture(manifest_path, eval_id, shim_path)
                    if not current_passed:
                        failure_stage = String("opcode_execution")
                        failure = String("P2SH script terminal result was false")
                elif is_p2pkh_diagnostic_fixture(eval_id):
                    current_passed = evaluate_p2pkh_fixture(manifest_path, eval_id, shim_path)
                    if not current_passed:
                        failure_stage = String("schnorr_verify")
                        failure = String("P2PKH ECDSA verification returned false")
                elif is_bare_legacy_diagnostic_fixture(eval_id):
                    current_passed = evaluate_bare_legacy_fixture(manifest_path, eval_id, shim_path)
                    if not current_passed:
                        failure_stage = String("opcode_execution")
                        failure = String("bare legacy script terminal result was false")
                elif is_witness_v0_diagnostic_fixture(eval_id):
                    current_passed = evaluate_witness_v0_fixture(manifest_path, eval_id, shim_path)
                    if not current_passed:
                        failure_stage = String("opcode_execution")
                        failure = String("witness v0 script terminal result was false")
                elif is_taproot_diagnostic_fixture(eval_id):
                    var taproot_result = evaluate_taproot_fixture_diagnostic(manifest_path, eval_id, shim_path)
                    current_passed = taproot_result.passed
                    failure_stage = taproot_result.failure_stage
                    failure = taproot_result.failure
                else:
                    failure_stage = String("unsupported_template")
                    failure = String("unsupported fixture in Mojo diagnostic corpus runner")
            except e:
                current_passed = False
                failure = String(e)
                failure_stage = diagnostic_failure_stage(failure)
            if current_passed:
                passed_count += 1
            else:
                failed_count += 1
            if fixture_count != 0:
                results += String(",")
            fixture_count += 1
            if shadow_crypto:
                var shadow_supported = False
                var shadow_agreed = False
                var shadow_result = String("unsupported")
                var shadow_failure_stage = String("")
                var shadow_failure = String("")
                var support_status = String("pure_backend_crypto_unsupported")
                var shadow_attempted = False
                var shadow_duration_ms = Int64(0)
                var shadow_tapscript_hex_bytes = Int64(0)
                var shadow_witness_items = 0
                var shadow_witness_hex_bytes = Int64(0)
                var shadow_ecdsa_sighash_ms = Int64(0)
                var shadow_ecdsa_verify_ms = Int64(0)
                var shadow_ecdsa_total_ms = Int64(0)
                var shadow_ecdsa_signature_count = 0
                if (
                    is_taproot_diagnostic_fixture(eval_id)
                    or is_p2pkh_diagnostic_fixture(eval_id)
                    or is_bare_legacy_diagnostic_fixture(eval_id)
                    or is_simple_p2sh_diagnostic_fixture(eval_id)
                    or is_witness_v0_diagnostic_fixture(eval_id)
                    or eval_id == "scripts.bare_multisig_27840"
                ):
                    if not pure_shadow_fixture_enabled(eval_id):
                        support_status = String("pure_backend_diagnostic_slice_not_enabled")
                    else:
                        shadow_attempted = True
                        var shadow_started = shadow_clock.now_ms()
                        try:
                            var pure_crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_PURE)
                            if is_taproot_diagnostic_fixture(eval_id):
                                shadow_tapscript_hex_bytes = taproot_shadow_tapscript_hex_bytes(manifest_path, eval_id)
                                shadow_witness_items = taproot_shadow_witness_count(eval_id)
                                shadow_witness_hex_bytes = taproot_shadow_witness_hex_bytes(manifest_path, eval_id)
                                var pure_result = evaluate_taproot_fixture_diagnostic_with_crypto(
                                    manifest_path, eval_id, shim_path, pure_crypto
                                )
                                shadow_duration_ms = shadow_clock.now_ms() - shadow_started
                                if pure_result.failure_stage == "unsupported_crypto":
                                    shadow_failure_stage = pure_result.failure_stage
                                    shadow_failure = pure_result.failure
                                else:
                                    shadow_supported = True
                                    shadow_result = result_json(pure_result.passed)
                                    shadow_agreed = pure_result.passed == current_passed
                                    support_status = String("supported")
                                    if not pure_result.passed:
                                        shadow_failure_stage = pure_result.failure_stage
                                        shadow_failure = pure_result.failure
                            else:
                                var pure_passed: Bool
                                if is_p2pkh_diagnostic_fixture(eval_id):
                                    var p2pkh_timer = OwnedDLHandle(shim_path)
                                    var timed_result = evaluate_p2pkh_fixture_with_crypto_timed(
                                        manifest_path, eval_id, shim_path, pure_crypto, p2pkh_timer
                                    )
                                    shadow_ecdsa_sighash_ms = timed_result.sighash_ms
                                    shadow_ecdsa_verify_ms = timed_result.verify_ms
                                    shadow_ecdsa_total_ms = timed_result.total_ms
                                    shadow_ecdsa_signature_count = timed_result.signature_count
                                    pure_passed = timed_result.passed
                                elif is_bare_legacy_diagnostic_fixture(eval_id):
                                    pure_passed = evaluate_bare_legacy_fixture_with_crypto(
                                        manifest_path, eval_id, shim_path, pure_crypto
                                    )
                                elif is_simple_p2sh_diagnostic_fixture(eval_id):
                                    pure_passed = evaluate_p2sh_fixture_with_crypto(
                                        manifest_path, eval_id, shim_path, pure_crypto
                                    )
                                elif is_witness_v0_diagnostic_fixture(eval_id):
                                    pure_passed = evaluate_witness_v0_fixture_with_crypto(
                                        manifest_path, eval_id, shim_path, pure_crypto
                                    )
                                else:
                                    var fixture = load_bare_multisig_fixture(manifest_path)
                                    pure_passed = evaluate_bare_multisig_fixture_with_crypto(
                                        fixture, shim_path, pure_crypto
                                    )
                                shadow_duration_ms = shadow_clock.now_ms() - shadow_started
                                shadow_supported = True
                                shadow_result = result_json(pure_passed)
                                shadow_agreed = pure_passed == current_passed
                                support_status = String("supported")
                                if not pure_passed:
                                    shadow_failure_stage = String("ecdsa_verify")
                                    shadow_failure = String("pure ECDSA verification returned false")
                        except e:
                            shadow_duration_ms = shadow_clock.now_ms() - shadow_started
                            shadow_failure = String(e)
                            shadow_failure_stage = diagnostic_failure_stage(shadow_failure)
                            if shadow_failure_stage != "unsupported_crypto":
                                shadow_supported = True
                                shadow_result = String("failed")
                                shadow_agreed = False
                                support_status = String("supported")
                        shadow_eval_ms += shadow_duration_ms
                        if shadow_supported:
                            shadow_supported_eval_ms += shadow_duration_ms
                        if shadow_duration_ms > shadow_max_row_ms:
                            shadow_max_row_ms = shadow_duration_ms
                            shadow_largest_duration_fixture = eval_id
                        if shadow_tapscript_hex_bytes > shadow_largest_tapscript_hex_bytes:
                            shadow_largest_tapscript_hex_bytes = shadow_tapscript_hex_bytes
                            shadow_largest_tapscript_fixture = eval_id
                if shadow_supported:
                    shadow_supported_count += 1
                if shadow_agreed:
                    shadow_agreed_count += 1
                if shadow_supported and not shadow_agreed:
                    shadow_disagreement_count += 1
                results += (
                    String('{"fixture_id":"')
                    + current_id
                    + String('","height":')
                    + String(meta.height)
                    + String(',"required_rules":"')
                    + meta.required_rules
                    + String('","native_result":"')
                    + result_json(current_passed)
                    + String('","shadow_result":"')
                    + shadow_result
                    + String('","shadow_supported":')
                    + bool_json(shadow_supported)
                    + String(',"shadow_agreed":')
                    + bool_json(shadow_agreed)
                    + String(',"shadow_backend":"mojo-pure-secp256k1","shadow_used_native_fallback":false,')
                    + String('"support_status":"')
                    + support_status
                    + String('"')
                )
                if shadow_attempted:
                    results += (
                        String(',"shadow_duration_ms":')
                        + String(shadow_duration_ms)
                        + String(',"shadow_tapscript_hex_bytes":')
                        + String(shadow_tapscript_hex_bytes)
                        + String(',"shadow_witness_items":')
                        + String(shadow_witness_items)
                        + String(',"shadow_witness_hex_bytes":')
                        + String(shadow_witness_hex_bytes)
                    )
                    if is_p2pkh_diagnostic_fixture(eval_id):
                        results += (
                            String(',"shadow_ecdsa_sighash_ms":')
                            + String(shadow_ecdsa_sighash_ms)
                            + String(',"shadow_ecdsa_verify_ms":')
                            + String(shadow_ecdsa_verify_ms)
                            + String(',"shadow_ecdsa_total_ms":')
                            + String(shadow_ecdsa_total_ms)
                            + String(',"shadow_ecdsa_signature_count":')
                            + String(shadow_ecdsa_signature_count)
                        )
                if not current_passed:
                    results += (
                        String(',"native_failure_stage":"')
                        + failure_stage
                        + String('","native_failure":"')
                        + failure
                        + String('"')
                    )
                if shadow_failure != "":
                    results += (
                        String(',"shadow_failure_stage":"')
                        + shadow_failure_stage
                        + String('","shadow_failure":"')
                        + shadow_failure
                        + String('"')
                    )
                results += String("}")
            else:
                results += (
                    String('{"fixture_id":"')
                    + current_id
                    + String('","height":')
                    + String(meta.height)
                    + String(',"required_rules":"')
                    + meta.required_rules
                    + String('","result":"')
                    + result_json(current_passed)
                    + String('"')
                )
                if not current_passed:
                    results += (
                        String(',"failure_stage":"')
                        + failure_stage
                        + String('","failure":"')
                        + failure
                        + String('"')
                    )
                results += String("}")
        var all_passed = failed_count == 0
        var json = String("")
        if shadow_crypto:
            json = (
                String('{"schema":"port.script_corpus_shadow_crypto.v1","category":"script_corpus_shadow_crypto",')
                + String('"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","runtime_surface":"')
                + surface
                + String('","entrypoint_language":"mojo","native_crypto_backend":"libsecp256k1",')
                + String('"shadow_crypto_backend":"mojo-pure-secp256k1","native_shim":"owned_c",')
                + String('"verifier":{"engine":"mojo_native","delegated":false,"shadow_crypto":true},')
                + String('"manifest":"')
                + manifest_path
                + String('","fixture_set":"all","fixture_count":')
                + String(fixture_count)
                + String(',"native_passed":')
                + String(passed_count)
                + String(',"native_failed":')
                + String(failed_count)
                + String(',"shadow_supported":')
                + String(shadow_supported_count)
                + String(',"shadow_unsupported":')
                + String(fixture_count - shadow_supported_count)
                + String(',"shadow_agreed":')
                + String(shadow_agreed_count)
                + String(',"disagreements":')
                + String(shadow_disagreement_count)
                + String(',"shadow_eval_ms":')
                + String(shadow_eval_ms)
                + String(',"shadow_supported_eval_ms":')
                + String(shadow_supported_eval_ms)
                + String(',"shadow_max_row_ms":')
                + String(shadow_max_row_ms)
                + String(',"shadow_largest_duration_fixture":"')
                + shadow_largest_duration_fixture
                + String('","shadow_largest_tapscript_fixture":"')
                + shadow_largest_tapscript_fixture
                + String('","shadow_largest_tapscript_hex_bytes":')
                + String(shadow_largest_tapscript_hex_bytes)
                + String(',"result":"diagnostic","results":[')
                + results
                + String("]}")
            )
        else:
            json = (
                String('{"schema":"port.script_corpus_result.v1","category":"script_corpus",')
                + String('"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","runtime_surface":"')
                + surface
                + String('","entrypoint_language":"mojo","native_crypto_backend":"libsecp256k1",')
                + String('"native_shim":"owned_c","verifier":{"engine":"')
                + verifier_engine
                + String('","delegated":false},')
                + String('"manifest":"')
                + manifest_path
                + String('","fixture_set":"')
                + fixture_set
                + String('","fixture_count":')
                + String(fixture_count)
                + String(',"passed":')
                + String(passed_count)
                + String(',"failed":')
                + String(failed_count)
                + String(',"result":"')
                + result_json(all_passed)
                + String('",')
                + String('"results":[')
                + results
                + String("]}")
            )
        if shadow_crypto and shadow_disagreement_count != 0:
            raise Error("shadow crypto disagreement")
        print(json)
        if result_path != "":
            var native = OwnedDLHandle(shim_path)
            _ = native.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        return

    if command == "pure-crypto-profile":
        var json = pure_crypto_profile_json(shim_path, surface)
        print(json)
        if result_path != "":
            var native = OwnedDLHandle(shim_path)
            _ = native.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        return

    if command == "pure-crypto-microbench":
        var json = pure_crypto_microbench_json(shim_path, surface, microbench_iterations, microbench_case, native_compare)
        print(json)
        if result_path != "":
            var native = OwnedDLHandle(shim_path)
            _ = native.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        return

    if command == "storage-proof":
        var native = Native(shim_path)
        var db = Int64(0)
        var create_ok = False
        var read_ok = False
        var delete_ok = False
        var batch_read_ok = False
        try:
            db = native.rocksdb_open(datadir)
            var key1 = ascii_string_to_bytes(String("mojo:owned:key1"))
            var key2 = ascii_string_to_bytes(String("mojo:owned:key2"))
            var value1 = ascii_string_to_bytes(String("value1"))
            var value2 = ascii_string_to_bytes(String("value2"))
            native.rocksdb_put(db, key1, value1)
            create_ok = True
            var read_value1 = native.rocksdb_get(db, key1, 128)
            read_ok = bytes_equal(read_value1, value1)
            native.rocksdb_put(db, key2, value2)
            native.rocksdb_delete(db, key1)
            delete_ok = True
            var missing_value1 = native.rocksdb_get(db, key1, 128)
            var read_value2 = native.rocksdb_get(db, key2, 128)
            batch_read_ok = len(missing_value1) == 0 and bytes_equal(read_value2, value2)
        except e:
            pass
        if db != 0:
            native.rocksdb_close(db)
        var passed = create_ok and read_ok and delete_ok and batch_read_ok
        var json = (
            String('{"schema":"port.storage_proof.v1","implementation":"Mojo",')
            + String('"port":"mojo","node_id":"mojobitnode","runtime_surface":"')
            + surface
            + String('","entrypoint_language":"mojo","native_shim":"owned_c","chain":"testnet4",')
            + String('"datadir":"')
            + datadir
            + String('","chainstate_backend":"rocksdb","runtime_truth_backend":"rocksdb",')
            + String('"rocksdb_runtime_truth":true,"chainstate_path":"')
            + datadir
            + String('/chainstate-rocksdb","native_storage":true,"operations":{"create":')
            + bool_json(create_ok)
            + String(',"read":')
            + bool_json(read_ok)
            + String(',"delete":')
            + bool_json(delete_ok)
            + String(',"batch_read":')
            + bool_json(batch_read_ok)
            + String('},"result":"')
            + result_json(passed)
            + String('"}')
        )
        print(json)
        if result_path != "":
            _ = native.handle.call["mojobitnode_write_text_len", Int32](
                result_path.unsafe_ptr(),
                Int32(result_path.byte_length()),
                json.unsafe_ptr(),
                Int32(json.byte_length()),
            )
        return

    if command == "local-reference-proof":
        var proof = local_reference_proof(
            shim_path,
            surface,
            datadir,
            peer,
            target,
            result_path,
            progress,
            shadow_crypto,
        )
        print(proof.json)
        return

    print("usage: mojobitnode <status|native-crypto-vectors|pure-crypto-profile|pure-crypto-microbench|storage-proof|script-corpus|script-corpus-dev|local-reference-proof> [options]")
