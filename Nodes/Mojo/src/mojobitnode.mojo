from std.ffi import OwnedDLHandle
from std.os import getenv
from std.sys import argv

from script_corpus_foundation import (
    evaluate_bare_legacy_fixture,
    evaluate_bare_multisig_fixture,
    evaluate_p2pkh_fixture,
    evaluate_p2sh_fixture,
    evaluate_taproot_fixture,
    evaluate_witness_v0_fixture,
    is_bare_legacy_diagnostic_fixture,
    is_p2pkh_diagnostic_fixture,
    is_simple_p2sh_diagnostic_fixture,
    is_taproot_diagnostic_fixture,
    is_witness_v0_diagnostic_fixture,
    load_bare_multisig_fixture,
    manifest_contains_fixture,
)
from script_corpus_table import fixture_meta, selected_fixture_ids


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


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: mojobitnode <status|native-crypto-vectors|storage-proof|script-corpus-dev> [options]")
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
        var native = OwnedDLHandle(shim_path)
        var case_total = native.call["mojobitnode_native_crypto_vector_count", Int32]()
        var passed_count = 0
        var results = String("")
        for i in range(Int(case_total)):
            var actual_code = native.call["mojobitnode_native_crypto_vector_actual", Int32](Int32(i))
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
            _ = native.call["mojobitnode_write_text", Int32](result_path.unsafe_ptr(), json.unsafe_ptr())
        return

    if command == "script-corpus-dev":
        var selected = selected_fixture_ids(fixture_id, fixture_set)
        var passed_count = 0
        var failed_count = 0
        var results = String("")
        for i in range(len(selected)):
            var current_id = selected[i]
            var meta = fixture_meta(current_id)
            var eval_id = String(meta.fixture_id)
            var current_passed = False
            var failure = String("")
            if not manifest_contains_fixture(manifest_path, eval_id):
                failure = String("fixture id not present in Shared manifest")
            elif eval_id == "scripts.bare_multisig_27840":
                var fixture = load_bare_multisig_fixture(manifest_path)
                current_passed = evaluate_bare_multisig_fixture(fixture, shim_path)
                if not current_passed:
                    failure = String("Mojo bare multisig evaluator returned false")
            elif is_simple_p2sh_diagnostic_fixture(eval_id):
                current_passed = evaluate_p2sh_fixture(manifest_path, eval_id, shim_path)
                if not current_passed:
                    failure = String("Mojo P2SH evaluator returned false")
            elif is_p2pkh_diagnostic_fixture(eval_id):
                current_passed = evaluate_p2pkh_fixture(manifest_path, eval_id, shim_path)
                if not current_passed:
                    failure = String("Mojo P2PKH evaluator returned false")
            elif is_bare_legacy_diagnostic_fixture(eval_id):
                current_passed = evaluate_bare_legacy_fixture(manifest_path, eval_id, shim_path)
                if not current_passed:
                    failure = String("Mojo bare legacy evaluator returned false")
            elif is_witness_v0_diagnostic_fixture(eval_id):
                current_passed = evaluate_witness_v0_fixture(manifest_path, eval_id, shim_path)
                if not current_passed:
                    failure = String("Mojo witness v0 evaluator returned false")
            elif is_taproot_diagnostic_fixture(eval_id):
                current_passed = evaluate_taproot_fixture(manifest_path, eval_id, shim_path)
                if not current_passed:
                    failure = String("Mojo Taproot/Tapscript evaluator returned false")
            else:
                failure = String("unsupported fixture in Mojo diagnostic corpus runner")
            if current_passed:
                passed_count += 1
            else:
                failed_count += 1
            if i != 0:
                results += String(",")
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
                results += String(',"failure":"') + failure + String('"')
            results += String("}")
        var all_passed = failed_count == 0
        var json = (
            String('{"schema":"port.script_corpus_result.v1","category":"script_corpus",')
            + String('"implementation":"Mojo","port":"mojo","node_id":"mojobitnode","runtime_surface":"')
            + surface
            + String('","entrypoint_language":"mojo","native_crypto_backend":"libsecp256k1",')
            + String('"native_shim":"owned_c","verifier":{"engine":"mojo_dev_foundation","delegated":false},')
            + String('"manifest":"')
            + manifest_path
            + String('","fixture_set":"')
            + fixture_set
            + String('","fixture_count":')
            + String(len(selected))
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
        print(json)
        if result_path != "":
            var native = OwnedDLHandle(shim_path)
            _ = native.call["mojobitnode_write_text", Int32](result_path.unsafe_ptr(), json.unsafe_ptr())
        return

    if command == "storage-proof":
        var native = OwnedDLHandle(shim_path)
        var mask = native.call["mojobitnode_storage_probe", Int32](datadir.unsafe_ptr())
        var create_ok = (mask & 1) != 0
        var read_ok = (mask & 2) != 0
        var delete_ok = (mask & 4) != 0
        var batch_read_ok = (mask & 8) != 0
        var passed = mask == 15
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
            _ = native.call["mojobitnode_write_text", Int32](result_path.unsafe_ptr(), json.unsafe_ptr())
        return

    print("usage: mojobitnode <status|native-crypto-vectors|storage-proof|script-corpus-dev> [options]")
