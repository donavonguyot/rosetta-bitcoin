from block_core import (
    BlockUtxoDelta,
    ConnectTiming,
    Native,
    ScriptVerifyResult,
    Utxo,
    _utxo_key,
    append_delta_created,
    append_delta_metadata,
    append_delta_undo,
    apply_block_delta,
    block_delta_unspent_created,
    check_pow,
    db_get_string,
    db_put_string,
    decode_utxo,
    encode_utxo,
    encode_block_undo,
    first_failed_script_result_index,
    hash_from_display,
    merkle_root,
    parse_block,
)
from script_corpus_foundation import (
    append_bytes,
    append_u32_le,
    append_varint,
    ascii_string_to_bytes,
    bytes_to_hex,
    hash160,
    hash256,
    parse_transaction,
    read_hex_file,
    serialize_tx_output,
    slice_bytes,
    tapleaf_hash,
    verify_taproot_tweak,
)
from std.collections import List
from std.os import getenv
from std.testing import assert_equal, assert_true, TestSuite


comptime FIRST_FIXTURE_TX = "../Shared/conformance/fixtures/scripts/scripts.bare_multisig_27840/tx_bare_multisig_27840.hex"
comptime TAPROOT_SCRIPTPATH_44295_SCRIPT = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_tapscript.hex"
comptime TAPROOT_SCRIPTPATH_44295_CONTROL = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_control_block.hex"
comptime TAPROOT_SCRIPTPATH_44295_PREV_SPK = "../Shared/conformance/fixtures/scripts/scripts.p2tr_scriptpath_44295/tx_p2tr_scriptpath_44295_prev_spk.hex"


def test_transaction_and_merkle_parse() raises:
    var tx_bytes = read_hex_file(FIRST_FIXTURE_TX)
    var tx = parse_transaction(tx_bytes.copy())
    assert_equal(len(tx.inputs), 1)
    assert_equal(len(tx.outputs), 1)
    var txid = hash256(tx_bytes)
    var header = List[UInt8]()
    for _ in range(80):
        header.append(UInt8(0))
    var merkle = txid.copy()
    for i in range(32):
        header[36 + i] = merkle[i]
    var block = List[UInt8]()
    append_bytes(block, header)
    append_varint(block, 1)
    append_bytes(block, tx_bytes)
    var parsed = parse_block(block)
    assert_equal(len(parsed.txs), 1)
    var root = merkle_root(parsed.txs)
    assert_equal(bytes_to_hex(root), bytes_to_hex(merkle))


def test_hash_and_pow_helpers() raises:
    var genesis = hash_from_display(String("00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"))
    assert_equal(bytes_to_hex(genesis), String("43f08bdab050e35b567c864b91f47f50ae725ae2de53bcfbbaf284da00000000"))
    assert_true(check_pow(genesis, UInt32(0x1D00FFFF)))


def test_utxo_codec() raises:
    var script = List[UInt8]()
    script.append(UInt8(0x76))
    script.append(UInt8(0xA9))
    script.append(UInt8(0x14))
    var payload = List[UInt8]()
    payload.append(UInt8(1))
    payload.append(UInt8(2))
    payload.append(UInt8(3))
    var h = hash160(payload)
    append_bytes(script, h)
    script.append(UInt8(0x88))
    script.append(UInt8(0xAC))
    var encoded = encode_utxo(101, Int64(5000000000), True, script)
    var decoded = decode_utxo(encoded)
    assert_equal(decoded.height, 101)
    assert_equal(decoded.value_sats, Int64(5000000000))
    assert_true(decoded.coinbase)
    assert_equal(bytes_to_hex(decoded.script_pubkey), bytes_to_hex(script))


def test_status_persistence() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_smoke"))
    db_put_string(native, db, String("validated_height"), String("5000"))
    db_put_string(native, db, String("chainstate_backend"), String("rocksdb"))
    assert_equal(db_get_string(native, db, String("validated_height")), String("5000"))
    assert_equal(db_get_string(native, db, String("chainstate_backend")), String("rocksdb"))
    native.rocksdb_close(db)


def test_native_crypto_metrics() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    native.crypto_metrics_reset()
    var tapscript = read_hex_file(TAPROOT_SCRIPTPATH_44295_SCRIPT)
    var control = read_hex_file(TAPROOT_SCRIPTPATH_44295_CONTROL)
    var script_pubkey = read_hex_file(TAPROOT_SCRIPTPATH_44295_PREV_SPK)
    assert_true(
        verify_taproot_tweak(
            shim,
            slice_bytes(control, 1, 33),
            tapleaf_hash(UInt8(0xC0), tapscript),
            slice_bytes(script_pubkey, 2, 34),
            Int(control[0] & UInt8(1)),
        )
    )
    assert_equal(native.crypto_metric(String("taproot_tweak_calls")), Int64(1))
    assert_true(native.crypto_metric(String("taproot_tweak_ms")) >= 0)


def test_block_job_failure_reduction_uses_lowest_tx_input_order() raises:
    var high = ScriptVerifyResult()
    high.job_index = 9
    high.completed = True
    high.ok = False
    high.tx_index = 4
    high.input_index = 0
    high.failure_stage = String("error")
    high.failure = String("late failure")

    var passed_result = ScriptVerifyResult()
    passed_result.job_index = 1
    passed_result.completed = True
    passed_result.ok = True

    var low = ScriptVerifyResult()
    low.job_index = 3
    low.completed = True
    low.ok = False
    low.tx_index = 2
    low.input_index = 1
    low.failure_stage = String("failed")
    low.failure = String("first failure")

    var results = List[ScriptVerifyResult]()
    results.append(high^)
    results.append(passed_result^)
    results.append(low^)

    assert_equal(first_failed_script_result_index(results), 2)


def test_block_delta_batch_apply_and_undo() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_batch_smoke"))
    var suffix = String(native.now_ms())

    var delta = BlockUtxoDelta()
    var txid = List[UInt8]()
    for i in range(32):
        txid.append(UInt8(i))
    var script = List[UInt8]()
    script.append(UInt8(0x51))
    var utxo = Utxo()
    utxo.height = 77
    utxo.value_sats = Int64(12345)
    utxo.coinbase = False
    utxo.script_pubkey = script.copy()

    append_delta_created(delta, txid, UInt32(0), utxo)
    delta.created_spent[0] = True
    assert_equal(block_delta_unspent_created(delta), 0)
    append_delta_undo(delta, 2, 1, txid, UInt32(0), utxo, True)

    delta.block_key = ascii_string_to_bytes(String("batch_smoke:block:") + suffix)
    delta.block_value = ascii_string_to_bytes(String("block-ok"))
    delta.undo_key = ascii_string_to_bytes(String("batch_smoke:undo:") + suffix)
    delta.undo_value = encode_block_undo(77, delta)
    var meta_name = String("batch_smoke_meta_") + suffix
    append_delta_metadata(delta, meta_name, String("meta-ok"))

    assert_equal(len(native.rocksdb_get(db, delta.block_key, 64)), 0)
    var timing = ConnectTiming()
    apply_block_delta(native, db, timing, delta)

    assert_equal(bytes_to_hex(native.rocksdb_get(db, delta.block_key, 64)), bytes_to_hex(delta.block_value))
    assert_true(len(native.rocksdb_get(db, delta.undo_key, 4096)) > 0)
    assert_equal(db_get_string(native, db, meta_name), String("meta-ok"))
    var suppressed_key = _utxo_key(txid, UInt32(0))
    assert_equal(len(native.rocksdb_get(db, suppressed_key, 4096)), 0)
    assert_true(timing.rocksdb_write >= 0)
    native.rocksdb_close(db)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
