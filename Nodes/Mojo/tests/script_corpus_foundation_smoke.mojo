from script_corpus_foundation import (
    bytes_to_hex,
    evaluate_taproot_fixture,
    hash160,
    hash256,
    load_bare_multisig_fixture,
    parse_bare_multisig_script,
    parse_push_only_stack,
    parse_transaction,
    read_hex_file,
    ripemd160_digest,
    sha1_digest,
    sha256_digest,
    slice_bytes,
    tapleaf_hash,
    taproot_signature_hash,
    TaprootPrevout,
    verify_taproot_tweak,
    verify_schnorr_signature,
)
from std.collections import List
from std.testing import assert_equal, assert_false, assert_true, TestSuite


comptime FIRST_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.bare_multisig_27840/tx_bare_multisig_27840.hex"
comptime SCRIPT_MANIFEST = "../Shared/conformance/fixtures/scripts/manifest.json"
comptime WITNESS_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.p2wsh_op1_only_31842/tx_p2wsh_op1_only_31842.hex"
comptime TAPROOT_NUMEQUAL_TX = "../Shared/conformance/fixtures/scripts/scripts.p2tr_tapscript_numequal_32712/tx_p2tr_tapscript_numequal_32712.hex"
comptime TAPROOT_NUMEQUAL_SCRIPT = "../Shared/conformance/fixtures/scripts/scripts.p2tr_tapscript_numequal_32712/tx_p2tr_tapscript_numequal_32712_tapscript.hex"
comptime TAPROOT_NUMEQUAL_PREV_SPK = "../Shared/conformance/fixtures/scripts/scripts.p2tr_tapscript_numequal_32712/tx_p2tr_tapscript_numequal_32712_prev_spk.hex"
comptime TAPROOT_NUMEQUAL_WITNESS_2 = "../Shared/conformance/fixtures/scripts/scripts.p2tr_tapscript_numequal_32712/tx_p2tr_tapscript_numequal_32712_witness_2.hex"
comptime TAPROOT_SCRIPTPATH_44295_TX = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295.hex"
comptime TAPROOT_SCRIPTPATH_44295_SCRIPT = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_tapscript.hex"
comptime TAPROOT_SCRIPTPATH_44295_CONTROL = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_control_block.hex"
comptime TAPROOT_SCRIPTPATH_44295_PREV_SPK = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_prev_spk.hex"


def test_read_hex_file() raises:
    var tx_bytes = read_hex_file(FIRST_FIXTURE_TX)
    assert_equal(len(tx_bytes), 232)
    assert_equal(Int(tx_bytes[0]), 1)
    assert_equal(Int(tx_bytes[1]), 0)
    assert_equal(Int(tx_bytes[2]), 0)
    assert_equal(Int(tx_bytes[3]), 0)


def test_sha256_known_vector() raises:
    var payload = List[UInt8]()
    payload.append(UInt8(97))
    payload.append(UInt8(98))
    payload.append(UInt8(99))
    assert_equal(
        bytes_to_hex(sha256_digest(payload)),
        String("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    )


def test_hash_known_vectors() raises:
    var empty = List[UInt8]()
    var payload = List[UInt8]()
    payload.append(UInt8(97))
    payload.append(UInt8(98))
    payload.append(UInt8(99))
    assert_equal(
        bytes_to_hex(sha1_digest(payload)),
        String("a9993e364706816aba3e25717850c26c9cd0d89d"),
    )
    assert_equal(
        bytes_to_hex(ripemd160_digest(empty)),
        String("9c1185a5c5e9fc54612808977ee8f548b2258d31"),
    )
    assert_equal(
        bytes_to_hex(ripemd160_digest(payload)),
        String("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc"),
    )
    assert_equal(
        bytes_to_hex(hash160(payload)),
        String("bb1be98c142444d7a56aa3981c3942a978e4dc33"),
    )
    assert_equal(
        bytes_to_hex(hash256(payload)),
        String("4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358"),
    )


def test_parse_legacy_transaction() raises:
    var tx = parse_transaction(read_hex_file(FIRST_FIXTURE_TX))
    assert_equal(tx.version, 1)
    assert_false(tx.has_witness)
    assert_equal(len(tx.inputs), 1)
    assert_equal(len(tx.outputs), 1)
    assert_equal(len(tx.inputs[0].previous_hash), 32)
    assert_equal(tx.inputs[0].previous_index, UInt32(0))
    assert_equal(len(tx.inputs[0].script_sig), 147)
    assert_equal(tx.inputs[0].sequence, UInt32(4294967295))
    assert_equal(tx.outputs[0].value, Int64(467644))
    assert_equal(len(tx.outputs[0].script_pubkey), 25)
    assert_equal(tx.lock_time, UInt32(0))


def test_parse_witness_transaction() raises:
    var tx = parse_transaction(read_hex_file(WITNESS_FIXTURE_TX))
    assert_equal(tx.version, 2)
    assert_true(tx.has_witness)
    assert_equal(len(tx.inputs), 6)
    assert_equal(len(tx.outputs), 1)
    assert_equal(len(tx.witness_item_count_by_input), 6)
    assert_equal(tx.lock_time, UInt32(0))


def test_load_bare_multisig_fixture() raises:
    var fixture = load_bare_multisig_fixture(SCRIPT_MANIFEST)
    assert_equal(fixture.fixture_id, String("scripts.bare_multisig_27840"))
    assert_equal(fixture.height, 27840)
    assert_equal(fixture.input_index, 0)
    assert_equal(fixture.prev_amount_sats, Int64(477645))
    assert_equal(fixture.required_rule, String("multisig"))
    assert_equal(len(fixture.tx.inputs), 1)
    assert_equal(len(fixture.tx.inputs[0].script_sig), 147)
    assert_equal(len(fixture.spent_script_pubkey), 201)


def test_bare_multisig_fixture_script_shape() raises:
    var fixture = load_bare_multisig_fixture(SCRIPT_MANIFEST)
    var stack = parse_push_only_stack(fixture.tx.inputs[0].script_sig)
    assert_equal(len(stack), 3)
    assert_equal(len(stack[0].data), 0)
    assert_equal(len(stack[1].data), 72)
    assert_equal(len(stack[2].data), 72)

    var script = parse_bare_multisig_script(fixture.spent_script_pubkey)
    assert_equal(script.required_signatures, 2)
    assert_equal(script.pubkey_count, 3)
    assert_equal(len(script.pubkeys), 3)
    assert_equal(len(script.pubkeys[0].data), 65)
    assert_equal(len(script.pubkeys[1].data), 65)
    assert_equal(len(script.pubkeys[2].data), 65)


def test_taproot_numequal_sighash_vector() raises:
    var tx = parse_transaction(read_hex_file(TAPROOT_NUMEQUAL_TX))
    var tapscript = read_hex_file(TAPROOT_NUMEQUAL_SCRIPT)
    var leaf_hash = tapleaf_hash(UInt8(0xC0), tapscript)
    assert_equal(
        bytes_to_hex(leaf_hash),
        String("541fe1ac9a1345074e2eef56faa6f7c0677f4596f727e2f6f859d970392c2419"),
    )
    var prevout = TaprootPrevout()
    prevout.amount = Int64(50000)
    prevout.script_pubkey = read_hex_file(TAPROOT_NUMEQUAL_PREV_SPK)
    var spent_prevouts = List[TaprootPrevout]()
    spent_prevouts.append(prevout^)
    var digest = taproot_signature_hash(tx, 0, spent_prevouts, UInt8(0), leaf_hash, 0xFFFFFFFF)
    assert_equal(
        bytes_to_hex(digest),
        String("d67ca3429e15437f51892a84390a719c9295db708211b4f82e7cdcd6ed0b9b48"),
    )


def test_taproot_numequal_schnorr_wrapper() raises:
    var tx = parse_transaction(read_hex_file(TAPROOT_NUMEQUAL_TX))
    var tapscript = read_hex_file(TAPROOT_NUMEQUAL_SCRIPT)
    var leaf_hash = tapleaf_hash(UInt8(0xC0), tapscript)
    var prevout = TaprootPrevout()
    prevout.amount = Int64(50000)
    prevout.script_pubkey = read_hex_file(TAPROOT_NUMEQUAL_PREV_SPK)
    var spent_prevouts = List[TaprootPrevout]()
    spent_prevouts.append(prevout^)
    var script_bytes = read_hex_file(TAPROOT_NUMEQUAL_SCRIPT)
    var pubkey = slice_bytes(script_bytes, 1, 33)
    assert_true(
        verify_schnorr_signature(
            String("./build/libmojobitnode_shim.dylib"),
            read_hex_file(TAPROOT_NUMEQUAL_WITNESS_2),
            pubkey,
            tx,
            0,
            spent_prevouts,
            leaf_hash,
            0xFFFFFFFF,
        )
    )


def test_taproot_numequal_fixture() raises:
    assert_true(
        evaluate_taproot_fixture(
            SCRIPT_MANIFEST,
            String("scripts.p2tr_tapscript_numequal_32712"),
            String("./build/libmojobitnode_shim.dylib"),
        )
    )


def test_taproot_scriptpath_44295_leaf_vector() raises:
    var tapscript = read_hex_file(TAPROOT_SCRIPTPATH_44295_SCRIPT)
    assert_equal(len(tapscript), 199)
    assert_equal(
        bytes_to_hex(tapleaf_hash(UInt8(0xC0), tapscript)),
        String("ed29ea908b65d979e36dc910f4d6d79c294c90bed47e9612116bcff2b7bb81ed"),
    )


def test_taproot_scriptpath_44295_tweak_wrapper() raises:
    var tapscript = read_hex_file(TAPROOT_SCRIPTPATH_44295_SCRIPT)
    var control = read_hex_file(TAPROOT_SCRIPTPATH_44295_CONTROL)
    var script_pubkey = read_hex_file(TAPROOT_SCRIPTPATH_44295_PREV_SPK)
    assert_true(
        verify_taproot_tweak(
            String("./build/libmojobitnode_shim.dylib"),
            slice_bytes(control, 1, 33),
            tapleaf_hash(UInt8(0xC0), tapscript),
            slice_bytes(script_pubkey, 2, 34),
            Int(control[0] & UInt8(1)),
        )
    )


def test_taproot_scriptpath_44295_fixture() raises:
    assert_true(
        evaluate_taproot_fixture(
            SCRIPT_MANIFEST,
            String("scripts.p2tr_scriptpath_44295"),
            String("./build/libmojobitnode_shim.dylib"),
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
