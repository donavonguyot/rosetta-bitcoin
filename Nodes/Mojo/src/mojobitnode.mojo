from std.collections import List
from std.ffi import OwnedDLHandle
from std.memory.unsafe_pointer import alloc
from std.os import getenv
from std.sys import argv

from block_core import Native, local_reference_proof
from script_corpus_foundation import (
    ascii_string_to_bytes,
    bytes_equal,
    CRYPTO_BACKEND_PURE,
    CryptoBackend,
    evaluate_bare_legacy_fixture,
    evaluate_bare_multisig_fixture,
    evaluate_p2pkh_fixture,
    evaluate_p2sh_fixture,
    evaluate_taproot_fixture,
    evaluate_taproot_fixture_diagnostic,
    evaluate_taproot_fixture_diagnostic_with_crypto,
    evaluate_witness_v0_fixture,
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
    # Keep the first pure-shadow corpus slice operationally bounded. Pure
    # Schnorr/Taproot vectors cover BIP340 and tweak primitives; this corpus row
    # proves the injected pure backend through the shared Taproot evaluator.
    return fixture_id == "scripts.p2tr_tapscript_numequal_32712"


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


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: mojobitnode <status|native-crypto-vectors|storage-proof|script-corpus|script-corpus-dev|local-reference-proof> [options]")
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
        var results = String("")
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
                if is_taproot_diagnostic_fixture(eval_id):
                    if not pure_shadow_fixture_enabled(eval_id):
                        support_status = String("pure_backend_diagnostic_slice_not_enabled")
                    else:
                        try:
                            var pure_crypto = CryptoBackend(shim_path, CRYPTO_BACKEND_PURE)
                            var pure_result = evaluate_taproot_fixture_diagnostic_with_crypto(
                                manifest_path, eval_id, shim_path, pure_crypto
                            )
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
                        except e:
                            shadow_failure = String(e)
                            shadow_failure_stage = diagnostic_failure_stage(shadow_failure)
                            if shadow_failure_stage != "unsupported_crypto":
                                shadow_supported = True
                                shadow_result = String("failed")
                                shadow_agreed = False
                                support_status = String("supported")
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
        var proof = local_reference_proof(shim_path, surface, datadir, peer, target, result_path, progress)
        print(proof.json)
        return

    print("usage: mojobitnode <status|native-crypto-vectors|storage-proof|script-corpus|script-corpus-dev|local-reference-proof> [options]")
