from script_corpus_foundation import (
    bytes_to_hex,
    load_bare_multisig_fixture,
    parse_bare_multisig_script,
    parse_push_only_stack,
    parse_transaction,
    read_hex_file,
    sha256_digest,
)
from std.collections import List
from std.testing import assert_equal, assert_false, assert_true, TestSuite


comptime FIRST_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.bare_multisig_27840/tx_bare_multisig_27840.hex"
comptime SCRIPT_MANIFEST = "../Shared/conformance/fixtures/scripts/manifest.json"
comptime WITNESS_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.p2wsh_op1_only_31842/tx_p2wsh_op1_only_31842.hex"


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
