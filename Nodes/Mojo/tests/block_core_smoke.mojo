from block_core import (
    BlockUtxoDelta,
    ConnectTiming,
    Native,
    PackedKeyIndex,
    ScriptVerifyResult,
    Utxo,
    _utxo_key,
    append_delta_created,
    append_delta_metadata,
    append_delta_undo,
    append_outpoint_if_missing,
    append_packed_batch_delete,
    append_packed_batch_put,
    apply_block_delta,
    block_delta_unspent_created,
    check_pow,
    contains_outpoint,
    db_get_string,
    db_put_string,
    decode_utxo,
    encode_utxo,
    encode_block_undo,
    find_created_delta_index,
    first_failed_script_result_index,
    hash_from_display,
    merkle_root,
    outpoint_index_key,
    parse_block,
    rocksdb_multi_get_rows,
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


def test_rocksdb_multi_get_order_and_missing_slots() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_multiget_smoke"))
    var suffix = String(native.now_ms())

    var key_a = ascii_string_to_bytes(String("multiget:a:") + suffix)
    var key_missing = ascii_string_to_bytes(String("multiget:missing:") + suffix)
    var key_b = ascii_string_to_bytes(String("multiget:b:") + suffix)
    var value_a = ascii_string_to_bytes(String("alpha"))
    var value_b = ascii_string_to_bytes(String("bravo"))
    native.rocksdb_put(db, key_a, value_a)
    native.rocksdb_put(db, key_b, value_b)

    var keys = List[List[UInt8]]()
    keys.append(key_a.copy())
    keys.append(key_missing.copy())
    keys.append(key_missing.copy())
    keys.append(key_b.copy())
    var rows = rocksdb_multi_get_rows(native, db, keys)
    assert_equal(len(rows), 4)
    assert_true(rows[0].found)
    assert_true(not rows[1].found)
    assert_true(not rows[2].found)
    assert_true(rows[3].found)
    assert_equal(bytes_to_hex(rows[0].value), bytes_to_hex(value_a))
    assert_equal(bytes_to_hex(rows[3].value), bytes_to_hex(value_b))
    native.rocksdb_close(db)


def test_packed_key_index_orders_and_finds_outpoints() raises:
    var txid_a = List[UInt8]()
    var txid_b = List[UInt8]()
    var txid_c = List[UInt8]()
    for _ in range(32):
        txid_a.append(UInt8(2))
        txid_b.append(UInt8(1))
        txid_c.append(UInt8(3))

    var index = PackedKeyIndex()
    assert_true(index.add_outpoint(txid_a, UInt32(5), 50))
    assert_true(index.add_outpoint(txid_b, UInt32(1), 10))
    assert_true(index.add_outpoint(txid_c, UInt32(2), 20))
    assert_true(not index.add_outpoint(txid_a, UInt32(5), 99))
    assert_equal(index.find_outpoint(txid_b, UInt32(1)), 10)
    assert_equal(index.find_outpoint(txid_c, UInt32(2)), 20)
    assert_equal(index.find_outpoint(txid_a, UInt32(5)), 50)
    assert_equal(index.find_outpoint(txid_a, UInt32(6)), -1)
    var key = outpoint_index_key(txid_a, UInt32(5))
    assert_equal(len(key), 36)


def test_outpoint_helpers_preserve_order_and_detect_duplicates() raises:
    var txid_a = List[UInt8]()
    var txid_b = List[UInt8]()
    for i in range(32):
        txid_a.append(UInt8(i))
        txid_b.append(UInt8(31 - i))

    var txids = List[List[UInt8]]()
    var vouts = List[UInt32]()
    assert_true(append_outpoint_if_missing(txids, vouts, txid_a, UInt32(0)))
    assert_true(append_outpoint_if_missing(txids, vouts, txid_b, UInt32(1)))
    assert_true(not append_outpoint_if_missing(txids, vouts, txid_a, UInt32(0)))
    assert_equal(len(txids), 2)
    assert_true(contains_outpoint(txids, vouts, txid_b, UInt32(1)))

    var delta = BlockUtxoDelta()
    var utxo = Utxo()
    utxo.height = 1
    utxo.value_sats = Int64(50)
    utxo.coinbase = False
    utxo.script_pubkey = ascii_string_to_bytes(String("script"))
    append_delta_created(delta, txid_a, UInt32(2), utxo)
    append_delta_created(delta, txid_b, UInt32(3), utxo)
    assert_equal(find_created_delta_index(delta, txid_a, UInt32(2)), 0)
    assert_equal(find_created_delta_index(delta, txid_b, UInt32(3)), 1)
    assert_equal(find_created_delta_index(delta, txid_b, UInt32(4)), -1)


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
    var txid_unspent = List[UInt8]()
    for i in range(32):
        txid.append(UInt8(i))
        txid_unspent.append(UInt8(255 - i))
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

    var external_key = ascii_string_to_bytes(String("batch_smoke:delete:") + suffix)
    var external_value = ascii_string_to_bytes(String("delete-me"))
    native.rocksdb_put(db, external_key, external_value)
    delta.external_spend_keys.append(external_key.copy())
    delta.external_spends += 1
    append_delta_created(delta, txid_unspent, UInt32(1), utxo)

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
    assert_equal(len(native.rocksdb_get(db, external_key, 64)), 0)
    var suppressed_key = _utxo_key(txid, UInt32(0))
    assert_equal(len(native.rocksdb_get(db, suppressed_key, 4096)), 0)
    var created_key = _utxo_key(txid_unspent, UInt32(1))
    assert_true(len(native.rocksdb_get(db, created_key, 4096)) > 0)
    assert_true(timing.rocksdb_write >= 0)
    assert_true(timing.rocksdb_batch_pack >= 0)
    native.rocksdb_close(db)


def test_packed_rocksdb_batch_apply_order() raises:
    var shim = getenv("MOJOBITNODE_SHIM_PATH", "./build/libmojobitnode_shim.dylib")
    var native = Native(shim)
    var db = native.rocksdb_open(String("/tmp/mojo_block_core_packed_batch_smoke"))
    var suffix = String(native.now_ms())

    var key_delete = ascii_string_to_bytes(String("packed:delete:") + suffix)
    var key_put = ascii_string_to_bytes(String("packed:put:") + suffix)
    var value_old = ascii_string_to_bytes(String("old"))
    var value_new = ascii_string_to_bytes(String("new"))
    native.rocksdb_put(db, key_delete, value_old)

    var packed = List[UInt8]()
    packed.append(UInt8(0))
    packed.append(UInt8(0))
    packed.append(UInt8(0))
    packed.append(UInt8(2))
    append_packed_batch_delete(packed, key_delete)
    append_packed_batch_put(packed, key_put, value_new)
    native.rocksdb_batch_apply_packed(db, packed)

    assert_equal(len(native.rocksdb_get(db, key_delete, 64)), 0)
    assert_equal(bytes_to_hex(native.rocksdb_get(db, key_put, 64)), bytes_to_hex(value_new))
    native.rocksdb_close(db)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
