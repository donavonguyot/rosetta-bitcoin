from __future__ import annotations

from pathlib import Path

import pytest

from pybitnode.chain.params import TESTNET4
from pybitnode.consensus.block import Block
from pybitnode.consensus.hash import hash160, hash256
from pybitnode.consensus.script.interpreter import Stack, evaluate_script, is_p2pk, is_p2pkh, verify_script, witness_program_version
from pybitnode.consensus.script.interpreter import _taproot_tweak_pubkey_xonly
from pybitnode.consensus.script.sighash import legacy_sighash, tapleaf_hash, taproot_signature_hash
from pybitnode.consensus.script.verify import ScriptVerifyError, verify_transaction_input
from pybitnode.consensus.secp256k1 import N, _scalar_mult, Gx, Gy, verify_der_signature
from pybitnode.messages.transaction import OutPoint, Transaction, TxIn, TxOut
from pybitnode.storage.blocks import BlockStore
from tests.blocks_fixture import FIXTURE_BLOCKS_DIR
from tests.script_helpers import (
    cltv_redeem_script,
    csv_redeem_script,
    make_signed_p2pk_spend,
    make_signed_p2pkh_spend,
    make_signed_p2sh_cltv_spend,
    make_signed_p2sh_csv_spend,
    make_signed_p2sh_multisig_spend,
    make_signed_p2sh_p2pkh_spend,
    make_signed_p2wpkh_spend,
    make_signed_p2wsh_cltv_spend,
    make_signed_p2wsh_csv_spend,
    make_signed_p2wsh_multisig_spend,
    make_signed_p2wsh_p2pkh_spend,
    multisig_redeem_script,
    p2pk_script_pubkey,
    p2pkh_script_pubkey,
    p2sh_script_pubkey,
)


FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _fixture_hex(name: str) -> bytes:
    return bytes.fromhex((FIXTURES_DIR / name).read_text().strip())


@pytest.fixture
def block1_fixture_payload() -> bytes:
    return BlockStore(FIXTURE_BLOCKS_DIR, TESTNET4.magic).read("blk00000.dat", 0, 258)


def test_verify_transaction_input_taproot_script_path_op_success():
    """
    Synthetic BIP341 script-path spend: single 0xc0 leaf with minimal tapscript OP_1 (truthy stack).
    Exercises Merkel path, output-key tweak parity, witness layout, same as mempool/connect_block callers.
    """
    internal_priv = 42
    point = _scalar_mult(internal_priv, (Gx, Gy))
    assert point is not None
    x_coord, y_coord = point
    if y_coord % 2 != 0:
        point = _scalar_mult((N - internal_priv) % N, (Gx, Gy))
        assert point is not None
        x_coord = point[0]
    internal_x = x_coord.to_bytes(32, "big")
    tapscript = bytes([0x51])  # OP_1
    merkle = tapleaf_hash(0xC0, tapscript)
    parity_q, output_xonly = _taproot_tweak_pubkey_xonly(internal_x, merkle)
    script_pubkey = bytes([0x51, 0x20]) + output_xonly
    control_block = bytes([0xC0 | (parity_q & 1)]) + internal_x

    amt = int(123_456_789)
    prev_hash = bytes.fromhex("33" * 32)
    spend = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_hash, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(TxOut(value=amt - 10_000, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((tapscript, control_block),),
    )
    spent_prevouts = ((amt, script_pubkey),)
    verify_transaction_input(
        spend,
        0,
        script_pubkey=script_pubkey,
        amount=amt,
        spent_prevouts=spent_prevouts,
    )


def test_verify_transaction_input_taproot_script_path_op_nip():
    """Synthetic tapscript OP_NIP: remove second stack item, leaving the top item truthy."""
    from pybitnode.consensus.script.opcodes import OP_NIP

    internal_priv = 43
    point = _scalar_mult(internal_priv, (Gx, Gy))
    assert point is not None
    x_coord, y_coord = point
    if y_coord % 2 != 0:
        point = _scalar_mult((N - internal_priv) % N, (Gx, Gy))
        assert point is not None
        x_coord = point[0]
    internal_x = x_coord.to_bytes(32, "big")
    tapscript = bytes([0x51, 0x52, OP_NIP])  # OP_1 OP_2 OP_NIP => leaves OP_2.
    merkle = tapleaf_hash(0xC0, tapscript)
    parity_q, output_xonly = _taproot_tweak_pubkey_xonly(internal_x, merkle)
    script_pubkey = bytes([0x51, 0x20]) + output_xonly
    control_block = bytes([0xC0 | (parity_q & 1)]) + internal_x

    amt = int(123_456_789)
    spend = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=bytes.fromhex("34" * 32), index=0),
                script_sig=b"",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(TxOut(value=amt - 10_000, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((tapscript, control_block),),
    )
    spent_prevouts = ((amt, script_pubkey),)
    verify_transaction_input(
        spend,
        0,
        script_pubkey=script_pubkey,
        amount=amt,
        spent_prevouts=spent_prevouts,
    )


def test_taproot_script_path_op_nip_stack_underflow_rejected():
    from pybitnode.consensus.script.opcodes import OP_NIP

    internal_priv = 44
    point = _scalar_mult(internal_priv, (Gx, Gy))
    assert point is not None
    x_coord, y_coord = point
    if y_coord % 2 != 0:
        point = _scalar_mult((N - internal_priv) % N, (Gx, Gy))
        assert point is not None
        x_coord = point[0]
    internal_x = x_coord.to_bytes(32, "big")
    tapscript = bytes([0x51, OP_NIP])  # Only one stack item: OP_NIP must fail.
    merkle = tapleaf_hash(0xC0, tapscript)
    parity_q, output_xonly = _taproot_tweak_pubkey_xonly(internal_x, merkle)
    script_pubkey = bytes([0x51, 0x20]) + output_xonly
    control_block = bytes([0xC0 | (parity_q & 1)]) + internal_x

    amt = int(123_456_789)
    spend = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=bytes.fromhex("35" * 32), index=0),
                script_sig=b"",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(TxOut(value=amt - 10_000, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((tapscript, control_block),),
    )
    spent_prevouts = ((amt, script_pubkey),)
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(
            spend,
            0,
            script_pubkey=script_pubkey,
            amount=amt,
            spent_prevouts=spent_prevouts,
        )


def test_legacy_script_op_nip_semantics_and_underflow():
    from pybitnode.consensus.script.opcodes import OP_NIP

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("36" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    assert verify_script(bytes([0x51, 0x52]), bytes([OP_NIP]), tx=tx, input_index=0, amount=1)
    assert not verify_script(bytes([0x51]), bytes([OP_NIP]), tx=tx, input_index=0, amount=1)


def test_batch1_stack_and_altstack_opcode_semantics():
    from pybitnode.consensus.script.opcodes import (
        OP_2DROP,
        OP_2DUP,
        OP_3DUP,
        OP_FROMALTSTACK,
        OP_IFDUP,
        OP_ROT,
        OP_TOALTSTACK,
    )

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("37" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    stack = Stack([b"\x01", b"\x02", b"\x03"])
    script = bytes([OP_2DUP, OP_ROT, OP_3DUP, OP_2DROP, OP_IFDUP, OP_TOALTSTACK, OP_FROMALTSTACK])
    evaluate_script(script, stack, tx=tx, input_index=0, script_code=script, amount=1, witness=False)
    assert stack == [b"\x01", b"\x02", b"\x02", b"\x03", b"\x03", b"\x02", b"\x02"]


def test_batch1_numeric_boolean_and_range_opcode_semantics():
    from pybitnode.consensus.script.opcodes import OP_0NOTEQUAL, OP_ABS, OP_BOOLAND, OP_NOT, OP_WITHIN

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("38" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    stack = Stack([b"\x83"])
    evaluate_script(bytes([OP_ABS]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x03"]

    stack = Stack([b"\x02", b""])
    evaluate_script(bytes([OP_NOT, OP_0NOTEQUAL]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x02", b"\x01"]

    stack = Stack([b"\x01", b"\x02"])
    evaluate_script(bytes([OP_BOOLAND]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01"]

    stack = Stack([b"\x05", b"\x03", b"\x08"])
    evaluate_script(bytes([OP_WITHIN]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01"]


def test_batch1_hash_opcodes_available_in_legacy_path():
    from pybitnode.consensus.script.opcodes import OP_RIPEMD160, OP_SHA1

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("39" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    stack = Stack([b"abc"])
    evaluate_script(bytes([OP_SHA1]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [bytes.fromhex("a9993e364706816aba3e25717850c26c9cd0d89d")]

    stack = Stack([b"abc"])
    evaluate_script(bytes([OP_RIPEMD160]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [bytes.fromhex("8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")]


def test_legacy_sighash_single_uses_null_outputs_before_signed_index():
    tx = Transaction(
        version=1,
        inputs=(
            TxIn(previous_output=OutPoint(hash=bytes.fromhex("11" * 32), index=0), script_sig=b"", sequence=0xFFFFFFFE),
            TxIn(previous_output=OutPoint(hash=bytes.fromhex("22" * 32), index=1), script_sig=b"", sequence=0xFFFFFFFD),
        ),
        outputs=(
            TxOut(value=1000, script_pubkey=b"\x51"),
            TxOut(value=2000, script_pubkey=b"\x51"),
        ),
        lock_time=0,
    )
    script_code = p2pkh_script_pubkey(bytes.fromhex("33" * 20))

    assert legacy_sighash(tx, 1, script_code, sighash_type=0x03).hex() == (
        "a804ca67698c6d01d8dcd010b20047ea15d503e19fe375378693f6552e67d280"
    )
    assert legacy_sighash(tx, 1, script_code, sighash_type=0x83).hex() == (
        "7554c4c62ff6c98e29b2aae36b04a78c514f55f5c1ce151950e7f715393f0fd8"
    )


def test_legacy_sighash_single_out_of_range_returns_uint256_one():
    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("12" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(),
        lock_time=0,
    )

    assert legacy_sighash(tx, 0, b"\x51", sighash_type=0x03) == b"\x01" + (b"\x00" * 31)


def test_batch2_legacy_stack_opcode_semantics():
    from pybitnode.consensus.script.opcodes import OP_2OVER, OP_2SWAP, OP_DEPTH, OP_NOP, OP_OVER, OP_PICK, OP_ROLL, OP_TUCK

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("3a" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    stack = Stack([b"\x01", b"\x02", b"\x03", b"\x04"])
    evaluate_script(bytes([OP_2OVER, OP_2SWAP]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01", b"\x02", b"\x01", b"\x02", b"\x03", b"\x04"]

    stack = Stack([b"\x01", b"\x02"])
    evaluate_script(bytes([OP_DEPTH, OP_NOP]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01", b"\x02", b"\x02"]

    stack = Stack([b"\x01", b"\x02", b"\x03", b"\x01"])
    evaluate_script(bytes([OP_PICK]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01", b"\x02", b"\x03", b"\x02"]

    stack = Stack([b"\x01", b"\x02", b"\x03", b"\x04", b"\x02"])
    evaluate_script(bytes([OP_ROLL, OP_OVER, OP_TUCK]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01", b"\x03", b"\x04", b"\x04", b"\x02", b"\x04"]


def test_batch2_legacy_boolean_and_minmax_opcode_semantics():
    from pybitnode.consensus.script.opcodes import OP_BOOLOR, OP_MAX, OP_MIN

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("3c" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    stack = Stack([b"", b"\x02"])
    evaluate_script(bytes([OP_BOOLOR]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x01"]

    stack = Stack([b"\x05", b"\x03"])
    evaluate_script(bytes([OP_MIN]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x03"]

    stack = Stack([b"\x05", b"\x03"])
    evaluate_script(bytes([OP_MAX]), stack, tx=tx, input_index=0, script_code=b"", amount=1, witness=False)
    assert stack == [b"\x05"]


def test_legacy_non_witness_allows_extra_stack_items_but_witness_stays_strict():
    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("3b" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    assert verify_script(bytes([0x51]), bytes([0x51]), tx=tx, input_index=0, amount=1)
    assert not verify_script(b"", bytes.fromhex("0014" + "11" * 20), tx=tx, input_index=0, amount=1, witness=(b"\x01", b"\x01"))


def test_real_testnet4_block6975_taproot_keypath_accepted():
    """
    Consensus fixture: testnet4 block 6975 spends a witness v1 (P2TR) output via key path only.
    See tx 12376f5a136a337ce4ea4025dbef2c18158945ef6aac58f2fc4d7c5fe81dff62 / prev vout 1.
    """
    tx_hex = (
        "020000000001016760fe836cb885189111d4e3cdb8c66446cdc85c1f4b2b43fdd8eea2fe0b0b96"
        "0100000000fdffffff02899b92f80e000000225120640d6c0f4087e81de6e82df09435fb9d4628999d38c124eaaecc98f165c889b0"
        "a086010000000000225120b6ce5933c68826bb261fe730f4f8a78b8a9f8898e1ce794d664abf0a9494ac59"
        "0140ecba16793ec416745da044701928f046da5761eacb384892cbde3c3706187251d3ca3c78adfde0eb560b0"
        "de89d4124023f0536be3d5e900960816780ae3d97f53d1b0000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c"
    )
    spent_prevouts = ((64300000000, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=64300000000, spent_prevouts=spent_prevouts)


def test_real_testnet4_block52024_p2tr_tapscript_sha256_accepted():
    """
    Consensus fixture: testnet4 block 52024 tx d57def62... input 0 spends P2TR
    via tapscript OP_SHA256 <hash> OP_EQUALVERIFY <x-only-pubkey> OP_CHECKSIG.
    """
    payload = _fixture_hex("tx_p2tr_tapscript_sha256_52024.hex")
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert len(tx.inputs) == 2
    assert len(tx.witness[0]) == 4

    prev_spk = _fixture_hex("tx_p2tr_tapscript_sha256_52024_prev_spk.hex")
    tapscript = _fixture_hex("tx_p2tr_tapscript_sha256_52024_tapscript.hex")
    assert tx.witness[0][-2] == tapscript
    assert tapscript[0] == 0xA8  # OP_SHA256
    assert tapscript[34] == 0x88  # OP_EQUALVERIFY
    assert tapscript[-1] == 0xAC  # OP_CHECKSIG

    spent_prevouts = (
        (1_200_000, prev_spk),
        (100_000_000, bytes.fromhex("0014fd641852669905e0191fc95a1881fb73952b5716")),
    )
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=1_200_000,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block52497_p2tr_tapscript_size_accepted():
    """
    Consensus fixture: testnet4 block 52497 tx c62c3c4c... input 0 spends P2TR
    via a tapscript dual-hashlock that uses OP_SIZE before a 2-of-2 Schnorr path.
    """
    payload = _fixture_hex("tx_p2tr_tapscript_size_52497.hex")
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert len(tx.inputs) == 1
    assert tx.inputs[0].script_sig == b""
    assert len(tx.witness[0]) == 6

    prev_spk = _fixture_hex("tx_p2tr_tapscript_size_52497_prev_spk.hex")
    tapscript = _fixture_hex("tx_p2tr_tapscript_size_52497_tapscript.hex")
    control_block = _fixture_hex("tx_p2tr_tapscript_size_52497_control_block.hex")
    assert tx.witness[0][-2] == tapscript
    assert tx.witness[0][-1] == control_block
    assert tapscript[0] == 0x76  # OP_DUP
    assert tapscript[1] == 0xA8  # OP_SHA256
    assert 0x82 in tapscript  # OP_SIZE
    assert tapscript[-1] == 0xAC  # OP_CHECKSIG

    spent_prevouts = ((1_000, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=1_000,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block41700_unknown_witness_v1_program_accepted():
    """
    Consensus fixture: testnet4 block 41700 spends a native SegWit v1 program that is not P2TR.
    Prevout cedcdf44...:1 has script 51024e73 (OP_1 <2-byte witness program>).
    """
    tx_hex = (
        "030000000113e6c813036baf66a64cf7ecac40afa190b414c9ca7770dac428a3fb44dfdcce"
        "0100000000fdffffff012c4c000000000000160014ecc94cde1ecd03d2dc6eeb45945516"
        "da19ea77aa00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex("51024e73")
    spent_prevouts = ((20_000, prev_spk),)

    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=20_000, spent_prevouts=spent_prevouts)


def test_unknown_witness_v1_program_rejects_non_empty_script_sig():
    tx = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=bytes.fromhex("44" * 32), index=0),
                script_sig=b"\x51",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(TxOut(value=1_000, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    prev_spk = bytes.fromhex("51024e73")

    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=2_000, spent_prevouts=((2_000, prev_spk),))


def test_real_testnet4_block44295_p2tr_tapscript_op_nip_accepted():
    """
    Consensus fixture: testnet4 block 44295 tx cb835ce1... input 0 spends an in-block
    P2TR output via tapscript ending OP_NIP (0x77).
    """
    tx_hex = (
        "02000000000101bf0d2b67f412514ae1388472a6e7c306f8addf7e1097c8edb1546e613662712c"
        "0000000000fdffffff012202000000000000225120d1c1c55764e7795ba8e627a80a78c5a140611f3d"
        "bef0464c7a0c85ca34d56a33034043bfb54dc9fd1d805b410778eeb3ce5e503199af73f5407251097"
        "18688eab3749e5b968cdf6efee67d54ece03976d60c94b4f00cccbb030c62ef046c707f24aec7206"
        "a4465638bd9c25d0b2e9da4985ee41c97e3e755e4d6ee95977fd6c8ed633a7aad0200000063400a"
        "a52e213e040b50c93f73e71fe7d5c9dd4c395b639cfc6b07818a070a6f638400e152c98150ab926"
        "0055c70369d69b1e5902f9fb6dea951a2c60ad2e72baf022103015a7c4d2cc1c771198686e2ebe"
        "f6fe7004f4136d61f6225b061d1bb9b821b9b310046ff23ef24364aa3280f7730e196b378a20982"
        "5c304bc3def5a1127cee6d9cac01000000000000000a000000000000006808a6f903000000000077"
        "21c06a4465638bd9c25d0b2e9da4985ee41c97e3e755e4d6ee95977fd6c8ed633a7a00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert hash256(tx.serialize())[::-1].hex() == "cb835ce1d726993515c27df94a358bf327b03323fb0e82c823c1faab31b28786"
    assert tx.witness[0][-2].endswith(b"\x77")

    prev_spk = bytes.fromhex(
        "5120346d44aef23b267970d8c090d8fed28e2dcf772b609f566cdc56e108ff84118a"
    )
    spent_prevouts = ((716, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=716, spent_prevouts=spent_prevouts)


def test_real_testnet4_block46599_p2tr_tapscript_truthy_0x80_prefix_accepted():
    """
    Consensus fixture: testnet4 block 46599 tx d1670431... input 0 spends an in-block
    P2TR output via tapscript. The final stack item is 809e000000000000, which is
    truthy because 0x80 is not the final sign byte of a zero-valued script number.
    """
    tx_hex = (
        "02000000000101436bd6415e01c9074876aa2401fea29b3ce8aa539ab42c14e2180d9a0a140af5"
        "0000000000fdffffff012202000000000000225120d1c1c55764e7795ba8e627a80a78c5a140611f3d"
        "bef0464c7a0c85ca34d56a330340f24c906a5037f699cc611f1261393eed3d66843a8912b67b5cb5d"
        "faac70333abe5b04c0fdd790a52811e416c5b50e5fbe12ccd25f26378b79676cfa61ecd45a5c720"
        "bafdef4404480c84301404bbf6dab8bdb609276b04604d0b593471387e8a4f6bad0200000063402e"
        "20c735bede90f250ba587ae6a7251839b5156562cf527eea907f43d36fb7a85e9d4ebaae52963820"
        "b1e304c49992ae212db5d973417cde20697009e7fc89102103015a7c4d2cc1c771198686e2ebef6"
        "fe7004f4136d61f6225b061d1bb9b821b9b3100e631ffb0e1804a68ae5f42444ec0e10bbbe878fa"
        "381de189fc7baff8df740ef3f3cd020000000000dad10200000000006808809e0000000000007721"
        "c0bafdef4404480c84301404bbf6dab8bdb609276b04604d0b593471387e8a4f6b00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert hash256(tx.serialize())[::-1].hex() == "d16704313ed3cd64f082c92b40d72ccf5ede213f739c3f217caf59f1ca6c962f"
    assert tx.witness[0][-2].endswith(bytes.fromhex("08809e00000000000077"))

    prev_spk = bytes.fromhex(
        "5120a23f913d1fc28f07abbcc72218ed00e0d149287b9e86187e54b0c6340ce584b3"
    )
    spent_prevouts = ((716, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=716, spent_prevouts=spent_prevouts)


def test_real_testnet4_block46779_p2wsh_codeseparator_accepted():
    """
    Consensus fixture: testnet4 block 46779 tx fb9b18c7... input 0 spends a native
    P2WSH output whose witness script executes OP_CODESEPARATOR before OP_CHECKSIG.
    """
    tx_hex = (
        "020000000001020dc0150d2844efb332aff927b5c7e8341f87741ffe568c3200f45df9cf5976fb"
        "0000000000fdffffff085d15233e2ef68a7a26226cbdfa40ea7088166181fc815e5e7de79b22"
        "f6d67e0000000000fdffffff0277040000000000000451024e7300f2052a010000001600143e"
        "a3e6ec3a8612e661a3cc2d79aed2f5fb46a81502473044022079be667ef9dcbbac55a06295c"
        "e870b07029bfcdb2dce28d959f2815b16f8179802205bc597cfbb5b01be850d68ebb65f5a15"
        "637b34a1dd3bc99293ca7901ef7d85e983298201509f69ab210279be667ef9dcbbac55a062"
        "95ce870b07029bfcdb2dce28d959f2815b16f81798ac02473044022060c5880f95e08aea07"
        "0a477e9921534d4c18646e444b87031be1d275bbf3018d02202401070862c823dab2e33320"
        "af4e29ae5793ba943713d0e04b1f2149074bb2b283210360f2408f00eff55b359a200acccb"
        "4766dabf90cc2fee6c4ae483118d3917706600000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert hash256(tx.serialize())[::-1].hex() == "fb9b18c782c2b45ccb77b4e22cbdf8b8cb1b8bf603289937968da52475e28aa5"
    assert tx.witness[0][-1] == bytes.fromhex(
        "8201509f69ab210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798ac"
    )

    prev_spk = bytes.fromhex("0020359eaf2fdfc8952db69827596cf6fe9093f203bdbbd83749a9953f58a3a93829")
    spent_prevouts = ((1143, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=1143, spent_prevouts=spent_prevouts)


def test_real_testnet4_block51340_p2sh_op_add_accepted():
    """
    Consensus fixture: testnet4 block 51340 tx 03911305... input 0 spends P2SH
    whose redeem script is OP_ADD OP_3 OP_EQUAL. scriptSig pushes 1, 2, and
    the redeem script, so legacy P2SH evaluation must leave true.
    """
    payload = _fixture_hex("tx_p2sh_add_51340.hex")
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert hash256(tx.serialize())[::-1].hex() == "03911305033a5aa73d7d730f16ba63b53582c6a6570d8d9f86e2f2b76fa2cbc3"
    assert tx.inputs[0].script_sig == _fixture_hex("tx_p2sh_add_51340_scriptsig.hex")
    assert _fixture_hex("tx_p2sh_add_51340_redeem_script.hex") == bytes.fromhex("935387")

    prev_spk = _fixture_hex("tx_p2sh_add_51340_prev_spk.hex")
    spent_prevouts = ((1500, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=1500, spent_prevouts=spent_prevouts)


def test_legacy_script_op_add_semantics_and_underflow():
    from pybitnode.consensus.script.opcodes import OP_ADD

    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("38" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )

    assert verify_script(bytes([0x51, 0x52]), bytes([OP_ADD, 0x53, 0x87]), tx=tx, input_index=0, amount=1)
    assert verify_script(bytes([0x4F, 0x52]), bytes([OP_ADD, 0x51, 0x87]), tx=tx, input_index=0, amount=1)
    assert not verify_script(bytes([0x51]), bytes([OP_ADD]), tx=tx, input_index=0, amount=1)

    # Arithmetic results may be wider than the 4-byte operand limit; later numeric
    # consumers would reject oversized values, but terminal truthiness must not.
    max_i32_push = bytes.fromhex("04ffffff7f")
    assert verify_script(max_i32_push + bytes([0x51]), bytes([OP_ADD]), tx=tx, input_index=0, amount=1)


def test_script_bool_cast_only_treats_final_0x80_as_negative_zero():
    tx = Transaction(
        version=1,
        inputs=(TxIn(previous_output=OutPoint(hash=bytes.fromhex("37" * 32), index=0), script_sig=b"", sequence=0),),
        outputs=(TxOut(value=1, script_pubkey=b""),),
        lock_time=0,
    )

    assert verify_script(bytes.fromhex("08809e000000000000"), b"", tx=tx, input_index=0, amount=1)
    assert not verify_script(bytes.fromhex("0180"), b"", tx=tx, input_index=0, amount=1)


def test_real_testnet4_block22830_taproot_script_path_if_accepted():
    """
    Consensus fixture: testnet4 block 22830 tx index 2 spends an in-block P2TR output
    via script-path tapscript using OP_IF/OP_ENDIF (metadata pushes skipped when branch false).
    Prevout created by tx 745ba1ca… vout 0 in the same block.
    """
    tx_hex = (
        "01000000000101c65a989a268eeec42278f50b5cac65202c81e4b1a064f5a8038c512acaa15b740000000000"
        "f5ffffff01220200000000000016001480a47c4cafd37bb161c3f4600537fe896e45bdc70340948e3f25c91"
        "df99942270cb22ef0dd7ac6814cccc928d5be0fe819a0886edccfc5a7eab4ebf381a177efb2cd55b95f4e25"
        "cbd76201047a3e918a7007da48e44f49207c6cea560462157a7cb01f84f076f60a0551f3cb78381673ae"
        "1410291ae97164ac00630674657374696400052f696e697401300131116170706c69636174696f6e2f6a617"
        "36f6e6821c07c6cea560462157a7cb01f84f076f60a0551f3cb78381673ae1410291ae9716400000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "5120f6b00789c732c14a921e61f2b1918a8a8db262d5b0aa2fb6e8229ce3870acda5"
    )
    spent_prevouts = ((798, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=798, spent_prevouts=spent_prevouts)


def test_real_testnet4_block27531_p2tr_tapscript_op2drop_accepted():
    """
    Consensus fixture: testnet4 block 27531 tx 1d03bf36… input 0 spends P2TR via
    script-path tapscript that uses OP_2DROP (Ordinals-style metadata then checksig).
    """
    tx_hex = (
        "0200000000010265b0cd6e5304d7ba45016f349928ccaa9ddce0a0633585276fc458bde9b66a850000000000ffffffff"
        "65b0cd6e5304d7ba45016f349928ccaa9ddce0a0633585276fc458bde9b66a850100000000ffffffff02220200000000"
        "0000160014bc5fa59b7108e0ec633e66233684bef4d4dbad48bc60070000000000160014bc5fa59b7108e0ec633e6623"
        "3684bef4d4dbad480340fdde995a6f4b8255526190c393ddb6537c4b44cf19fcbe5a4828c0e70335dbd01b4a709d9ed7"
        "cab242703f670b9519802d836e2dc95af7d21a30b239c496f91ec64c5089a7626974776f726ba433323330a364656308"
        "a36c696dcf000000746a528800a36d6178cf000775f05a074000a26f70a66465706c6f79a170a36e3230a3736368d940"
        "353062313336313964346439334636643763356337666237646662653735326533336238356233333737346539653262"
        "3337373966313637393166623163373439a57374617274cd6b8aa47469636ba44e4f5445000000044e4f54456d6d6d20"
        "da6c71b73fb5462258b16c60f30465fc5985fe9e63610e671f7c8bfddab3b115ac41c1da6c71b73fb5462258b16c60f3"
        "0465fc5985fe9e63610e671f7c8bfddab3b1152a56124065fd50baecd89ca4204fbfaa0b66021d78891c9b7b9255a11b"
        "1341140247304402200c920c11b85599f02c6567ef8bbc3046588a5b772173ca2118ae77170714ff6702202298ea7333"
        "bae79fad9deda4c4915f45d7112d6831c448561ff47969543b6f60012102da6c71b73fb5462258b16c60f30465fc5985"
        "fe9e63610e671f7c8bfddab3b11500000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    p2tr_spk = bytes.fromhex(
        "5120dcbb5a309840814ae2a29ebf31390e9d9ba352db3b4e81f3a1cdb0b3c40755ff"
    )
    p2wpkh_spk = bytes.fromhex("0014bc5fa59b7108e0ec633e66233684bef4d4dbad48")
    spent_prevouts = ((546, p2tr_spk), (483781, p2wpkh_spk))
    for input_index, (amount, script_pubkey) in enumerate(spent_prevouts):
        verify_transaction_input(
            tx,
            input_index,
            script_pubkey=script_pubkey,
            amount=amount,
            spent_prevouts=spent_prevouts,
        )



def test_real_testnet4_block28527_p2tr_large_tapscript_accepted():
    """
    Consensus fixture: testnet4 block 28527 tx d459f9eb… input 0 spends P2TR via
    script-path tapscript (~15444 bytes; BIP342 has no 10k script-size cap).
    """
    tx_hex = (
        "020000000001013407bdcce0fa4a155b0638938441b6ec493e3633b8bca1a30b4b9ac829032dd000"
        "0000000000000000014a01000000000000225120ac4dd6439e3cda1950b823965113fb113c2aa971"
        "a7ec7a85f5915198042fff900341b3473399ca5191bc5d82d67a82812bc80212fad57bafc9fc7b64"
        "bc859fd7e994f0df42d7bf5fc7ce80486cf28f104c554bb9ca7d014d64045280d31d1eacd63501fd"
        "543c207f18b14a0da1a5e1b4fd9ad5542b4b57d74fb43275810d827a696caf1b75f1ffac0063036f"
        "726401010a746578742f706c61696e004d08020063036f726401010a746578742f706c61696e004c"
        "827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438"
        "30326533386663383839393639343137636439306466346334313437323039643261383365643833"
        "373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b"
        "223a22373335313438227d680063036f726401010a746578742f706c61696e004c827b2270223a22"
        "746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663"
        "38383939363934313763643930646634633431343732303964326138336564383337393863306334"
        "6161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2237333138"
        "3739227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f"
        "70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934"
        "31376364393064663463343134373230396432613833656438333739386330633461613433393161"
        "64333665356930222c227469636b223a22626974222c22626c6b223a22323633353335227d680063"
        "036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d74"
        "2d6d696e74222c22646570223a2239343234384d0802303265333866633838393936393431376364"
        "39306466346334313437323039643261383365643833373938633063346161343339316164333665"
        "356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f7264"
        "01010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e"
        "74222c22646570223a22393432343830326533386663383839393639343137636439306466346334"
        "313437323039643261383365643833373938633063346161343339316164333665356930222c2274"
        "69636b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a74657874"
        "2f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570"
        "223a2239343234383032653338666338383939363934313763643930646634633431343732303964"
        "3261383365643833373938633063346161343339316164333665356930222c227469636b223a2262"
        "6974222c22626c6b223a22373335313438227d680063036f726401010a746578742f706c61696e00"
        "4c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234"
        "38303265333866633838393936393431376364393064663463343134373230396432613833656438"
        "333739386330633461613433393161643336653569304d0802222c227469636b223a22626974222c"
        "22626c6b223a22373331383739227d680063036f726401010a746578742f706c61696e004c827b22"
        "70223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265"
        "33386663383839393639343137636439306466346334313437323039643261383365643833373938"
        "633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a22"
        "323633353335227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170"
        "222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663383839"
        "39363934313763643930646634633431343732303964326138336564383337393863306334616134"
        "3339316164333665356930222c227469636b223a22626974222c22626c6b223a2236303437303522"
        "7d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a"
        "22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934313763"
        "64393064663463343134373230396432613833656438333739386330633461613433393161643336"
        "65356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f72"
        "6401010a746578742f706c61696e004c827b2270223a2274614d080270222c226f70223a22646d74"
        "2d6d696e74222c22646570223a223934323438303265333866633838393936393431376364393064"
        "66346334313437323039643261383365643833373938633063346161343339316164333665356930"
        "222c227469636b223a22626974222c22626c6b223a22373335313438227d680063036f726401010a"
        "746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c"
        "22646570223a22393432343830326533386663383839393639343137636439306466346334313437"
        "323039643261383365643833373938633063346161343339316164333665356930222c227469636b"
        "223a22626974222c22626c6b223a22373331383739227d680063036f726401010a746578742f706c"
        "61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22"
        "39343234383032653338666338383939363934313763643930646634633431343732303964326138"
        "3365643833373938633063346161343339316164333665356930222c227469636b223a2262697422"
        "2c22626c6b223a22323633353335227d680063036f726401010a746578742f706c61696e004c827b"
        "2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032"
        "653338666338383939363934313763643930646634633431343732304d0802396432613833656438"
        "33373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c"
        "6b223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b2270223a"
        "22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866"
        "63383839393639343137636439306466346334313437323039643261383365643833373938633063"
        "346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a22363034"
        "373035227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c22"
        "6f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663383839393639"
        "34313763643930646634633431343732303964326138336564383337393863306334616134333931"
        "6164333665356930222c227469636b223a22626974222c22626c6b223a22373335313438227d6800"
        "63036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d"
        "742d6d696e74222c22646570223a2239343234383032653338666338383939363934313763643930"
        "64663463343134373230396432613833656438333739386330633461613433393161643336653569"
        "30222c227469636b223a22626974222c22626c6b223a22373331383739227d4d0802680063036f72"
        "6401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d69"
        "6e74222c22646570223a223934323438303265333866633838393936393431376364393064663463"
        "34313437323039643261383365643833373938633063346161343339316164333665356930222c22"
        "7469636b223a22626974222c22626c6b223a22323633353335227d680063036f726401010a746578"
        "742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c226465"
        "70223a22393432343830326533386663383839393639343137636439306466346334313437323039"
        "643261383365643833373938633063346161343339316164333665356930222c227469636b223a22"
        "626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61696e"
        "004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432"
        "34383032653338666338383939363934313763643930646634633431343732303964326138336564"
        "3833373938633063346161343339316164333665356930222c227469636b223a22626974222c2262"
        "6c6b223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b227022"
        "3a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432344d0802383032"
        "65333866633838393936393431376364393064663463343134373230396432613833656438333739"
        "38633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a"
        "22373335313438227d680063036f726401010a746578742f706c61696e004c827b2270223a227461"
        "70222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866633838"
        "39393639343137636439306466346334313437323039643261383365643833373938633063346161"
        "343339316164333665356930222c227469636b223a22626974222c22626c6b223a22373331383739"
        "227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f7022"
        "3a22646d742d6d696e74222c22646570223a22393432343830326533386663383839393639343137"
        "63643930646634633431343732303964326138336564383337393863306334616134333931616433"
        "3665356930222c227469636b223a22626974222c22626c6b223a22323633353335227d680063036f"
        "726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d"
        "696e74222c22646570223a2239343234383032653338666338383939363934313763643930646634"
        "633431343732303964326138336564383337393863306334616134333931616433366535694d0802"
        "30222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f72640101"
        "0a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e7422"
        "2c22646570223a223934323438303265333866633838393936393431376364393064663463343134"
        "37323039643261383365643833373938633063346161343339316164333665356930222c22746963"
        "6b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f70"
        "6c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a"
        "22393432343830326533386663383839393639343137636439306466346334313437323039643261"
        "383365643833373938633063346161343339316164333665356930222c227469636b223a22626974"
        "222c22626c6b223a22373335313438227d680063036f726401010a746578742f706c61696e004c82"
        "7b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830"
        "32653338666338383939363934313763643930646634633431343732303964326138336564383337"
        "3938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b22"
        "3a22373331383739227d680063036f726401010a746578742f706c61696e004c827b2270223a2274"
        "4d08026170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338"
        "66633838393936393431376364393064663463343134373230396432613833656438333739386330"
        "63346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a223236"
        "33353335227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c"
        "226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866633838393936"
        "39343137636439306466346334313437323039643261383365643833373938633063346161343339"
        "316164333665356930222c227469636b223a22626974222c22626c6b223a22363034373035227d68"
        "0063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a2264"
        "6d742d6d696e74222c22646570223a22393432343830326533386663383839393639343137636439"
        "30646634633431343732303964326138336564383337393863306334616134333931616433366535"
        "6930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f726401"
        "010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74"
        "222c22646570223a2239343234383032653338666338383939363934313763643930646634633431"
        "3437324d08023039643261383365643833373938633063346161343339316164333665356930222c"
        "227469636b223a22626974222c22626c6b223a22373335313438227d680063036f726401010a7465"
        "78742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c2264"
        "6570223a223934323438303265333866633838393936393431376364393064663463343134373230"
        "39643261383365643833373938633063346161343339316164333665356930222c227469636b223a"
        "22626974222c22626c6b223a22373331383739227d680063036f726401010a746578742f706c6169"
        "6e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934"
        "32343830326533386663383839393639343137636439306466346334313437323039643261383365"
        "643833373938633063346161343339316164333665356930222c227469636b223a22626974222c22"
        "626c6b223a22323633353335227d680063036f726401010a746578742f706c61696e004c827b2270"
        "223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533"
        "38666338383939363934313763643930646634633431343732303964326138336564383337393863"
        "3063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2236"
        "3034373035224d08027d680063036f726401010a746578742f706c61696e004c827b2270223a2274"
        "6170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338"
        "38393936393431376364393064663463343134373230396432613833656438333739386330633461"
        "61343339316164333665356930222c227469636b223a22626974222c22626c6b223a223630343730"
        "35227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70"
        "223a22646d742d6d696e74222c22646570223a223934323438303265333866633838393936393431"
        "37636439306466346334313437323039643261383365643833373938633063346161343339316164"
        "333665356930222c227469636b223a22626974222c22626c6b223a22373335313438227d68006303"
        "6f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d"
        "6d696e74222c22646570223a22393432343830326533386663383839393639343137636439306466"
        "34633431343732303964326138336564383337393863306334616134333931616433366535693022"
        "2c227469636b223a22626974222c22626c6b223a22373331383739227d680063036f726401010a74"
        "6578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22"
        "646570223a223934324d080234383032653338666338383939363934313763643930646634633431"
        "3437323039643261383365643833373938633063346161343339316164333665356930222c227469"
        "636b223a22626974222c22626c6b223a22323633353335227d680063036f726401010a746578742f"
        "706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c2264657022"
        "3a223934323438303265333866633838393936393431376364393064663463343134373230396432"
        "61383365643833373938633063346161343339316164333665356930222c227469636b223a226269"
        "74222c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61696e004c"
        "827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438"
        "30326533386663383839393639343137636439306466346334313437323039643261383365643833"
        "373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b"
        "223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b2270223a22"
        "746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663"
        "38383939363934313763643930646634633431343732303964326138336564383337393863306334"
        "6161343339316164333665354d08026930222c227469636b223a22626974222c22626c6b223a2237"
        "3335313438227d680063036f726401010a746578742f706c61696e004c827b2270223a2274617022"
        "2c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338383939"
        "36393431376364393064663463343134373230396432613833656438333739386330633461613433"
        "39316164333665356930222c227469636b223a22626974222c22626c6b223a22373331383739227d"
        "680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22"
        "646d742d6d696e74222c22646570223a223934323438303265333866633838393936393431376364"
        "39306466346334313437323039643261383365643833373938633063346161343339316164333665"
        "356930222c227469636b223a22626974222c22626c6b223a22323633353335227d680063036f7264"
        "01010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e"
        "74222c22646570223a22393432343830326533386663383839393639343137636439306466346334"
        "313437323039643261383365643833373938633063346161343339316164333665356930222c2274"
        "69636b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a74657874"
        "2f706c61696e004c827b2270223a224d0802746170222c226f70223a22646d742d6d696e74222c22"
        "646570223a2239343234383032653338666338383939363934313763643930646634633431343732"
        "3039643261383365643833373938633063346161343339316164333665356930222c227469636b22"
        "3a22626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61"
        "696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239"
        "34323438303265333866633838393936393431376364393064663463343134373230396432613833"
        "65643833373938633063346161343339316164333665356930222c227469636b223a22626974222c"
        "22626c6b223a22373335313438227d680063036f726401010a746578742f706c61696e004c827b22"
        "70223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265"
        "33386663383839393639343137636439306466346334313437323039643261383365643833373938"
        "633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a22"
        "373331383739227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170"
        "222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663383839"
        "3936393431376364393064663463343134374d080232303964326138336564383337393863306334"
        "6161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2232363335"
        "3335227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f"
        "70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934"
        "31376364393064663463343134373230396432613833656438333739386330633461613433393161"
        "64333665356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063"
        "036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d74"
        "2d6d696e74222c22646570223a223934323438303265333866633838393936393431376364393064"
        "66346334313437323039643261383365643833373938633063346161343339316164333665356930"
        "222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a"
        "746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c"
        "22646570223a22393432343830326533386663383839393639343137636439306466346334313437"
        "323039643261383365643833373938633063346161343339316164333665356930222c227469636b"
        "223a22626974222c22626c6b223a223733353134384d0802227d680063036f726401010a74657874"
        "2f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570"
        "223a2239343234383032653338666338383939363934313763643930646634633431343732303964"
        "3261383365643833373938633063346161343339316164333665356930222c227469636b223a2262"
        "6974222c22626c6b223a22373331383739227d680063036f726401010a746578742f706c61696e00"
        "4c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234"
        "38303265333866633838393936393431376364393064663463343134373230396432613833656438"
        "33373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c"
        "6b223a22323633353335227d680063036f726401010a746578742f706c61696e004c827b2270223a"
        "22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866"
        "63383839393639343137636439306466346334313437323039643261383365643833373938633063"
        "346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a22363034"
        "373035227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c22"
        "6f70223a22646d742d6d696e74222c22646570223a2239344d080232343830326533386663383839"
        "39363934313763643930646634633431343732303964326138336564383337393863306334616134"
        "3339316164333665356930222c227469636b223a22626974222c22626c6b223a2236303437303522"
        "7d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a"
        "22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934313763"
        "64393064663463343134373230396432613833656438333739386330633461613433393161643336"
        "65356930222c227469636b223a22626974222c22626c6b223a22373335313438227d680063036f72"
        "6401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d69"
        "6e74222c22646570223a223934323438303265333866633838393936393431376364393064663463"
        "34313437323039643261383365643833373938633063346161343339316164333665356930222c22"
        "7469636b223a22626974222c22626c6b223a22373331383739227d680063036f726401010a746578"
        "742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c226465"
        "70223a22393432343830326533386663383839393639343137636439306466346334313437323039"
        "6432613833656438333739386330633461613433393161643336654d0802356930222c227469636b"
        "223a22626974222c22626c6b223a22323633353335227d680063036f726401010a746578742f706c"
        "61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22"
        "39343234383032653338666338383939363934313763643930646634633431343732303964326138"
        "3365643833373938633063346161343339316164333665356930222c227469636b223a2262697422"
        "2c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b"
        "2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032"
        "65333866633838393936393431376364393064663463343134373230396432613833656438333739"
        "38633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a"
        "22363034373035227d680063036f726401010a746578742f706c61696e004c827b2270223a227461"
        "70222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866633838"
        "39393639343137636439306466346334313437323039643261383365643833373938633063346161"
        "343339316164333665356930222c227469636b223a22626974222c22626c6b223a22373335313438"
        "227d680063036f726401010a746578742f706c61696e004c827b2270223a4d080222746170222c22"
        "6f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663383839393639"
        "34313763643930646634633431343732303964326138336564383337393863306334616134333931"
        "6164333665356930222c227469636b223a22626974222c22626c6b223a22373331383739227d6800"
        "63036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d"
        "742d6d696e74222c22646570223a2239343234383032653338666338383939363934313763643930"
        "64663463343134373230396432613833656438333739386330633461613433393161643336653569"
        "30222c227469636b223a22626974222c22626c6b223a22323633353335227d680063036f72640101"
        "0a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e7422"
        "2c22646570223a223934323438303265333866633838393936393431376364393064663463343134"
        "37323039643261383365643833373938633063346161343339316164333665356930222c22746963"
        "6b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f70"
        "6c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a"
        "2239343234383032653338666338383939363934313763643930646634633431344d080237323039"
        "643261383365643833373938633063346161343339316164333665356930222c227469636b223a22"
        "626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61696e"
        "004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432"
        "34383032653338666338383939363934313763643930646634633431343732303964326138336564"
        "3833373938633063346161343339316164333665356930222c227469636b223a22626974222c2262"
        "6c6b223a22373335313438227d680063036f726401010a746578742f706c61696e004c827b227022"
        "3a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338"
        "66633838393936393431376364393064663463343134373230396432613833656438333739386330"
        "63346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a223733"
        "31383739227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c"
        "226f70223a22646d742d6d696e74222c22646570223a223934323438303265333866633838393936"
        "39343137636439306466346334313437323039643261383365643833373938633063346161343339"
        "316164333665356930222c227469636b223a22626974222c22626c6b223a2232363335334d080235"
        "227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f7022"
        "3a22646d742d6d696e74222c22646570223a22393432343830326533386663383839393639343137"
        "63643930646634633431343732303964326138336564383337393863306334616134333931616433"
        "3665356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f"
        "726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d"
        "696e74222c22646570223a2239343234383032653338666338383939363934313763643930646634"
        "6334313437323039643261383365643833373938633063346161343339316164333665356930222c"
        "227469636b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a7465"
        "78742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c2264"
        "6570223a223934323438303265333866633838393936393431376364393064663463343134373230"
        "39643261383365643833373938633063346161343339316164333665356930222c227469636b223a"
        "22626974222c22626c6b223a22373335313438227d680063036f726401010a746578742f706c6169"
        "6e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22394d"
        "08023432343830326533386663383839393639343137636439306466346334313437323039643261"
        "383365643833373938633063346161343339316164333665356930222c227469636b223a22626974"
        "222c22626c6b223a22373331383739227d680063036f726401010a746578742f706c61696e004c82"
        "7b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830"
        "32653338666338383939363934313763643930646634633431343732303964326138336564383337"
        "3938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b22"
        "3a22323633353335227d680063036f726401010a746578742f706c61696e004c827b2270223a2274"
        "6170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338"
        "38393936393431376364393064663463343134373230396432613833656438333739386330633461"
        "61343339316164333665356930222c227469636b223a22626974222c22626c6b223a223630343730"
        "35227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70"
        "223a22646d742d6d696e74222c22646570223a223934323438303265333866633838393936393431"
        "37636439306466346334313437323039643261383365643833373938633063346161343339316164"
        "33364d080265356930222c227469636b223a22626974222c22626c6b223a22363034373035227d68"
        "0063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a2264"
        "6d742d6d696e74222c22646570223a22393432343830326533386663383839393639343137636439"
        "30646634633431343732303964326138336564383337393863306334616134333931616433366535"
        "6930222c227469636b223a22626974222c22626c6b223a22373335313438227d680063036f726401"
        "010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74"
        "222c22646570223a2239343234383032653338666338383939363934313763643930646634633431"
        "3437323039643261383365643833373938633063346161343339316164333665356930222c227469"
        "636b223a22626974222c22626c6b223a22373331383739227d680063036f726401010a746578742f"
        "706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c2264657022"
        "3a223934323438303265333866633838393936393431376364393064663463343134373230396432"
        "61383365643833373938633063346161343339316164333665356930222c227469636b223a226269"
        "74222c22626c6b223a22323633353335227d680063036f726401010a746578742f706c61696e004c"
        "827b2270224d08023a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934"
        "32343830326533386663383839393639343137636439306466346334313437323039643261383365"
        "643833373938633063346161343339316164333665356930222c227469636b223a22626974222c22"
        "626c6b223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b2270"
        "223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533"
        "38666338383939363934313763643930646634633431343732303964326138336564383337393863"
        "3063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2236"
        "3034373035227d680063036f726401010a746578742f706c61696e004c827b2270223a2274617022"
        "2c226f70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338383939"
        "36393431376364393064663463343134373230396432613833656438333739386330633461613433"
        "39316164333665356930222c227469636b223a22626974222c22626c6b223a22373335313438227d"
        "680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22"
        "646d742d6d696e74222c22646570223a223934323438303265333866633838393936393431376364"
        "39306466346334314d08023437323039643261383365643833373938633063346161343339316164"
        "333665356930222c227469636b223a22626974222c22626c6b223a22373331383739227d68006303"
        "6f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d"
        "6d696e74222c22646570223a22393432343830326533386663383839393639343137636439306466"
        "34633431343732303964326138336564383337393863306334616134333931616433366535693022"
        "2c227469636b223a22626974222c22626c6b223a22323633353335227d680063036f726401010a74"
        "6578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22"
        "646570223a2239343234383032653338666338383939363934313763643930646634633431343732"
        "3039643261383365643833373938633063346161343339316164333665356930222c227469636b22"
        "3a22626974222c22626c6b223a22363034373035227d680063036f726401010a746578742f706c61"
        "696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239"
        "34323438303265333866633838393936393431376364393064663463343134373230396432613833"
        "65643833373938633063346161343339316164333665356930222c227469636b223a22626974222c"
        "22626c6b223a22363034374d08023035227d680063036f726401010a746578742f706c61696e004c"
        "827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438"
        "30326533386663383839393639343137636439306466346334313437323039643261383365643833"
        "373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b"
        "223a22373335313438227d680063036f726401010a746578742f706c61696e004c827b2270223a22"
        "746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663"
        "38383939363934313763643930646634633431343732303964326138336564383337393863306334"
        "6161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2237333138"
        "3739227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f"
        "70223a22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934"
        "31376364393064663463343134373230396432613833656438333739386330633461613433393161"
        "64333665356930222c227469636b223a22626974222c22626c6b223a22323633353335227d680063"
        "036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d74"
        "2d6d696e74222c22646570223a224d08023934323438303265333866633838393936393431376364"
        "39306466346334313437323039643261383365643833373938633063346161343339316164333665"
        "356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f7264"
        "01010a746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e"
        "74222c22646570223a22393432343830326533386663383839393639343137636439306466346334"
        "313437323039643261383365643833373938633063346161343339316164333665356930222c2274"
        "69636b223a22626974222c22626c6b223a22363034373035227d680063036f726401010a74657874"
        "2f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570"
        "223a2239343234383032653338666338383939363934313763643930646634633431343732303964"
        "3261383365643833373938633063346161343339316164333665356930222c227469636b223a2262"
        "6974222c22626c6b223a22373335313438227d680063036f726401010a746578742f706c61696e00"
        "4c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234"
        "38303265333866633838393936393431376364393064663463343134373230396432613833656438"
        "33373938633063346161343339316164334d08023665356930222c227469636b223a22626974222c"
        "22626c6b223a22373331383739227d680063036f726401010a746578742f706c61696e004c827b22"
        "70223a22746170222c226f70223a22646d742d6d696e74222c22646570223a223934323438303265"
        "33386663383839393639343137636439306466346334313437323039643261383365643833373938"
        "633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b223a22"
        "323633353335227d680063036f726401010a746578742f706c61696e004c827b2270223a22746170"
        "222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663383839"
        "39363934313763643930646634633431343732303964326138336564383337393863306334616134"
        "3339316164333665356930222c227469636b223a22626974222c22626c6b223a2236303437303522"
        "7d680063036f726401010a746578742f706c61696e004c827b2270223a22746170222c226f70223a"
        "22646d742d6d696e74222c22646570223a2239343234383032653338666338383939363934313763"
        "64393064663463343134373230396432613833656438333739386330633461613433393161643336"
        "65356930222c227469636b223a22626974222c22626c6b223a22363034373035227d680063036f72"
        "6401010a746578742f706c61696e004c827b22704d0802223a22746170222c226f70223a22646d74"
        "2d6d696e74222c22646570223a223934323438303265333866633838393936393431376364393064"
        "66346334313437323039643261383365643833373938633063346161343339316164333665356930"
        "222c227469636b223a22626974222c22626c6b223a22373335313438227d680063036f726401010a"
        "746578742f706c61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c"
        "22646570223a22393432343830326533386663383839393639343137636439306466346334313437"
        "323039643261383365643833373938633063346161343339316164333665356930222c227469636b"
        "223a22626974222c22626c6b223a22373331383739227d680063036f726401010a746578742f706c"
        "61696e004c827b2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a22"
        "39343234383032653338666338383939363934313763643930646634633431343732303964326138"
        "3365643833373938633063346161343339316164333665356930222c227469636b223a2262697422"
        "2c22626c6b223a22323633353335227d680063036f726401010a746578742f706c61696e004c827b"
        "2270223a22746170222c226f70223a22646d742d6d696e74222c22646570223a2239343234383032"
        "65333866633838393936393431376364393064663463344cdc313437323039643261383365643833"
        "373938633063346161343339316164333665356930222c227469636b223a22626974222c22626c6b"
        "223a22363034373035227d680063036f726401010a746578742f706c61696e004c827b2270223a22"
        "746170222c226f70223a22646d742d6d696e74222c22646570223a22393432343830326533386663"
        "38383939363934313763643930646634633431343732303964326138336564383337393863306334"
        "6161343339316164333665356930222c227469636b223a22626974222c22626c6b223a2236303437"
        "3035227d686821c07f18b14a0da1a5e1b4fd9ad5542b4b57d74fb43275810d827a696caf1b75f1ff"
        "05010000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "51202c82fd5b4bd04b8fafb3851c49831d10c91ed8f7541672db0d5cd6fadcc3dea9"
    )
    spent_prevouts = ((4312, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=4312, spent_prevouts=spent_prevouts)


def test_real_testnet4_block27251_p2wsh_if_else_multisig_accepted():
    """
    Consensus fixture: testnet4 block 27251 tx a66a655d… spends P2WSH with
    OP_IF single-sig / OP_ELSE 2-of-3 CHECKMULTISIG (branch selector 0x01 on stack).
    """
    tx_hex = (
        "0200000000010330fd8a6ec9e4f44fc690ba3ba5e93c3a6d09cb0537588bc11119bda171cbbdad00"
        "00000000fdffffff49eb5af1fc023de7db36334047b36234b67df236deec89787072371a30cc7635"
        "000000000000000000b49e81ecb56a49ca3bac4ad4d2ea9f51a1c80e556e37a6cf2beddb15289ba0"
        "fa00000000000000000003ea6401000000000022002059895dadf481ae39d8f1404dda7829fe69be"
        "0c626cb3bf7555d61f25141824870000000000000000086a0653594d423a31401f00000000000016"
        "0014b060d86fee83ed5c39a2387565434e45e040a128034730440220593ba46b896548f94c499ad8"
        "febc09fe2dd398686c41a70bb3cca05b2b470de702201e29b5c0c7d2fcef9988196629d1cb23d9e4"
        "990e5890c07e530aa349561538d28101018f632103edc032007bf3aadf1435674fc7bf352752840c"
        "ab77e65ee63cf8ceea9d95ab72ac67522102a8115cc83c92b96febd544fba01f928c9718c8c0c541"
        "1ab6aa117d20dd5973d721029ccad61e1379d85c1207196df8b882c8b8f4a2193990630f70e0fcee"
        "8b1114572103ec76c51c504720c017909bd29fa5d54e049502d5584b1bb25ed3a72fdba60f4553ae"
        "680347304402207d84e8684ef21b07326b94a68423960d6df045404b5d1a34517c06d82ee839a602"
        "206304835dfaef5515ce6f73646759a696671a1294a3456f071f3c28d2efb42fb78101018f632103"
        "edc032007bf3aadf1435674fc7bf352752840cab77e65ee63cf8ceea9d95ab72ac67522102a8115c"
        "c83c92b96febd544fba01f928c9718c8c0c5411ab6aa117d20dd5973d721029ccad61e1379d85c12"
        "07196df8b882c8b8f4a2193990630f70e0fcee8b1114572103ec76c51c504720c017909bd29fa5d5"
        "4e049502d5584b1bb25ed3a72fdba60f4553ae68034730440220267fe9bdc55320ee73aa47207c69"
        "b04da6eeb2ab58ac643fe229b615c0a7926302204bb269d08adc3acfec5f9217684f41e3ca0da101"
        "d46b9d909c8714d9f39b86c78101018f632103edc032007bf3aadf1435674fc7bf352752840cab77"
        "e65ee63cf8ceea9d95ab72ac67522102a8115cc83c92b96febd544fba01f928c9718c8c0c5411ab6"
        "aa117d20dd5973d721029ccad61e1379d85c1207196df8b882c8b8f4a2193990630f70e0fcee8b11"
        "14572103ec76c51c504720c017909bd29fa5d54e049502d5584b1bb25ed3a72fdba60f4553ae6800"
        "000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "0020e51d37e194ce5fb07c41c7301cdcd6391713c93c276fe115384172e86c8ba660"
    )
    spent_prevouts = (
        (10000, prev_spk),
        (10000, prev_spk),
        (79761, prev_spk),
    )
    for input_index, (amount, script_pubkey) in enumerate(spent_prevouts):
        verify_transaction_input(
            tx,
            input_index,
            script_pubkey=script_pubkey,
            amount=amount,
            spent_prevouts=spent_prevouts,
        )


def test_real_testnet4_block27807_p2sh_if_else_sha256_accepted():
    """
    Consensus fixture: testnet4 block 27807 tx d1a68c8f… input 0 spends P2SH with
    OP_IF (numeric branch) / OP_ELSE OP_SHA256 OP_EQUALVERIFY / OP_ENDIF OP_CHECKSIG.
    Branch selector is empty push (OP_0); preimage push is ASCII '810899055'.
    """
    script_sig = bytes.fromhex(
        "473044022050bc43a3a4f534abbcedddb6fa2b30b499afdcba5d3c0018407a14da310e35650220642a4d4909878223fa79a2dba896ae827ad2cd1513d6fbe3869cf863cc8d0ea601"
        "09383130383939303535004c72630220247c940118a06967a8206009b3c19a19f84e6b5208493a411939d0f49a90b462aa55b5b32466602c80b48868410443a74996f06a600889469f3f982345d7ce7e55081713daaaba42c317f18897d6ad9f0246eed4d0a9a3d684330df0aa0c3fde697de7312315244123cc2309eb74ac"
    )
    tx = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(
                    hash=bytes.fromhex(
                        "52ceb80c5c7a5a0eb6bd2fe84de9aaf119b6339e74648e300c3175ae0174c7d5"
                    )[::-1],
                    index=0,
                ),
                script_sig=script_sig,
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(
            TxOut(
                value=479170,
                script_pubkey=bytes.fromhex(
                    "76a914645acca60cdf566f9999b4b540da3ea18a29fb3d88ac"
                ),
            ),
        ),
        lock_time=0,
    )
    prev_spk = bytes.fromhex("a914d569ebaca3b27115a284275caae03594e3e50db687")
    spent_prevouts = ((489171, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=489171,
        spent_prevouts=spent_prevouts,
    )


def test_legacy_evaluate_script_hash_opcodes():
    """Legacy evaluate_script implements standard hash/compare opcodes."""
    import hashlib

    from pybitnode.consensus.hash import hash160, hash256, sha256_digest
    from pybitnode.consensus.script.interpreter import Stack, evaluate_script

    tx = Transaction(version=1, inputs=(), outputs=(), lock_time=0)
    data = b"810899055"
    cases = (
        (0xA6, hashlib.new("ripemd160", data).digest()),
        (0xA7, hashlib.sha1(data).digest()),
        (0xA8, sha256_digest(data)),
        (0xA9, hash160(data)),
        (0xAA, hash256(data)),
    )
    for opcode, expected in cases:
        stack = Stack([data])
        evaluate_script(
            bytes([opcode]),
            stack,
            tx=tx,
            input_index=0,
            script_code=b"",
            amount=0,
            witness=False,
        )
        assert stack[-1] == expected

    digest = sha256_digest(data)
    stack = Stack([b"leftover", data])
    evaluate_script(
        bytes([0xA8, len(digest)]) + digest + bytes([0x88]),
        stack,
        tx=tx,
        input_index=0,
        script_code=b"",
        amount=0,
        witness=False,
    )
    assert stack == [b"leftover"]


def test_legacy_evaluate_script_stack_arithmetic_opcodes():
    """Legacy evaluate_script implements SWAP, SUB, and GREATERTHAN for P2SH branches."""
    from pybitnode.consensus.script.interpreter import Stack, evaluate_script

    tx = Transaction(version=1, inputs=(), outputs=(), lock_time=0)

    stack = Stack([b"\x01", b"\x02"])
    evaluate_script(
        bytes([0x7C]),
        stack,
        tx=tx,
        input_index=0,
        script_code=b"",
        amount=0,
        witness=False,
    )
    assert stack == [b"\x02", b"\x01"]

    stack = Stack([b"\xe8\x07", b"\xd1\x07"])  # 2024, 2001
    evaluate_script(
        bytes([0x94]),
        stack,
        tx=tx,
        input_index=0,
        script_code=b"",
        amount=0,
        witness=False,
    )
    assert stack == [b"\x17"]  # 23

    stack = Stack([b"\x17", b"\x12"])  # 23, 18
    evaluate_script(
        bytes([0xA0]),
        stack,
        tx=tx,
        input_index=0,
        script_code=b"",
        amount=0,
        witness=False,
    )
    assert stack == [b"\x01"]


def test_real_testnet4_block27903_p2sh_p2wpkh_nested_segwit_accepted():
    """
    Consensus fixture: testnet4 block 27903 tx 0ec62ece… input 0 spends P2SH-wrapped
    P2WPKH (redeem script 0x0014{hash160}; witness stack sig + pubkey).
    """
    tx_hex = (
        "020000000001010516efe23fba95e675b10ba8e2183446d804869421a22f778598a60994148a6a0000000017"
        "16001480a680ecd9fab9de5919782bdbbd1a30d02d1f16fdffffff02809ba9a600000000160014f684a9c65"
        "f7694dcf3f2ca38fc848957ee8ff53c0049070000000000160014114bf3675aa6e770c8e2e55183b5bc384"
        "4dbb37a02473044022041ea4484c5847d132ab8fd91861df56375f0b8bc5ec4f311c603f2b6efa33da102"
        "200f85040849cfedba7a1738191ab8a19bd48e1de74b4c47efb12c1051642d483d0121020c86c4c759fbe"
        "38248902a352b1f1347cae351b8863a948f64c7a599c1eaf442fe6c0000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex("a91475de6c813ade07e332add7055b960470be4db23a87")
    spent_prevouts = ((2796610852, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=2796610852,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block30622_p2tr_tapscript_checksigadd_2of3_accepted():
    """
    Consensus fixture: testnet4 block 30622 tx c185ee54… input 0 spends P2TR script-path
    with 2-of-3 tapscript multisig using CHECKSIG + CHECKSIGADD + OP_2 OP_GREATERTHANOREQUAL.
    """
    tx_hex = (
        "020000000001018b19273d590e8672a6642637b19eea2ab87aefcb26a1311ff0878ebb873d41f601000"
        "00000ffffffff0188130000000000002251205ba9446d820fa0f14c80fee3bd48168866fc7365964eb2"
        "fc130323e3ee70f577050040417fbc1c60fcfdc86c9c909a15ca6f6e63ff7ca6feee2904390ee33ba6"
        "bd2d45ed25e421190294a1d528864bfe18da37a9b71c23e4fb740193847993a9da088740179e0707c5"
        "c1441ab41ac6f98933b7162f18e032b23103bcd44bf9d111278617218d88b444c513f30c04700f942"
        "fb82fd77c94712036f1effc625a08e630b0346820728379fce21f06916b9cf5112bbda9e4c94d74515"
        "a300895c6200796dcb4703cac20d05700fb4c24556a495f1fac235df6ef8b6bb208fbcc1221f2111e5"
        "cf0e4ba0cba20dc2af8c9662198883dab4f2b1cc98657aa7e0a6dcfb239436873d74dfa76569cba52"
        "a221c150929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac000000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "51205ba9446d820fa0f14c80fee3bd48168866fc7365964eb2fc130323e3ee70f577"
    )
    spent_prevouts = ((100000, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=100000,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block30695_p2wsh_if_hashlock_op_size_accepted():
    """
    Consensus fixture: testnet4 block 30695 tx 1ec1f5f5… input 0 spends P2WSH with
    OP_IF hashlock branch (OP_SIZE + SHA256 + P2PKH) / OP_ELSE CLTV branch / OP_ENDIF
    OP_EQUALVERIFY OP_CHECKSIG. IF branch selector is OP_1; interpreter must support OP_SIZE (0x82).
    """
    tx_hex = (
        "020000000001012fda3f13d37d4684fddba53dee5003fc573a7e6aa930bbf43785d1cfb650c79d"
        "000000000000000000017d15000000000000160014c621dd55c3655eff54899ce7478ea5db35286eae"
        "05473044022024941388006148ac24fbb527b5d79a85dcd044c224d5be9aa40803c2f28abe08022062"
        "ccf546d39e34e9a3d3d0391f0471b73a43a72d44084e2e7b55eb4f1f3b3c4e0121023610a0b6e5e69aff"
        "2c2f0aedfe58cde5e0bcb221c41f2a71f63f6e26683362772024d2b60f4fabcd8c08babbaf64d27a80"
        "e329dc058caae644886c1790fcc71f5f0101616382012088a820a8ce9f3c4b104194e123dc5ca0c86a5"
        "42718ef129cb3ef9a21b89119e0332fbe8876a914c621dd55c3655eff54899ce7478ea5db35286eae"
        "670428067366b17576a91441fe346f7fcf6f0c4c1124a402658b492b9ec28d6888ac00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "002062583e521abfb23c6c0e2d0cc900f74a1f9b7c9e06739dd61c4ab95cb07a2af9"
    )
    spent_prevouts = ((5693, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=5693,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block38010_p2pkh_sighash_single_sequence_accepted():
    """
    Consensus fixture: testnet4 block 38010 tx ba32ba8e… input 0 spends P2PKH with
    SIGHASH_SINGLE (0x03) and nSequence 0xfffffffd; legacy sighash must keep the
    signing input sequence (Core RawSignatureHash), not zero it for NONE/SINGLE.
    """
    tx_hex = (
        "0200000001c3e04198db4e9eb0dfee9fbeabd80eb9252d499e0806e374fa2d22f3f933fe9500000000"
        "6a4730440220646ec8d2de9071b56db28360419e67fa3cff82c252f095dd29172aa4d8b2ab8902206263"
        "044bd60fb29247245eab482460c5344930efbaed8822c747fc72445e131d0321030c5d72e18c004dbd15f236"
        "d07f936aff3fea431973d140684e99fcaa8fd63f47fdffffff01a64f8b5e254e00001976a914547b12df8"
        "d80764f833b023191d8e0d1b8c6ca6788ac79940000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex("76a9149ec1ccfb40904402ee1d0a1c332c503772f22b3188ac")
    spent_prevouts = ((85922406945143, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=85922406945143,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block33500_p2sh_p2wsh_op1_only_witness_accepted():
    """
    Consensus fixture: testnet4 block 33500 tx f89a4629… input 0 spends P2SH-wrapped P2WSH
    with witness script OP_1 only; nested path must allow len(witness)==1 like native P2WSH.
    """
    tx_hex = (
        "02000000000103c97f44b92d58efccad4d999ab88c7f09820e4361a1ca82b28ccd77d24e4340c200000"
        "000232200204ae81572f06e1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260fdffffff"
        "349c489599535a954318f96b4ee8392f61cd6d7b15459c6ef846722745089d1c0100000023220020"
        "4ae81572f06e1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260fdffffff682aaa7bf9"
        "30358d556fabead40f441279f958f186c955ce4f9197191be28b1a00000000232200204ae81572f06e"
        "1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260fdffffff0120ef02000000000017a914"
        "56e0a0b78861b85d20ab028baf390e50d4d47baf8701015101015101015100000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex("a91472c44f957fc011d97e3406667dca5b1c930c402687")
    spent_prevouts = ((62819, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=62819,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block32712_p2tr_tapscript_checksigadd_2of3_numequal_accepted():
    """
    Consensus fixture: testnet4 block 32712 tx 6b586a4f… input 0 spends P2TR script-path
    with 2-of-3 tapscript using CHECKSIG + CHECKSIGADD + OP_2 OP_NUMEQUAL (not GTE).
    """
    tx_hex = (
        "02000000000101ad635a2ca7032be95f1c0f56244078306397c6c8c0c6dfd216c50f2e29505f840100"
        "000000ffffffff01c8af0000000000002251203a6c36818562ca3aa86741eb70dda13da67a5977255fc"
        "8af67109c8dbdd9f3ca050040108b74784f6995e6b05c79c0ce19e5398601f1a3b69800e00a8bff"
        "3163f209f31e1b24f76c02299e3e44899ca501d9c4cbe73810a147c1b52c8fc25b87552c01402862"
        "adde17553bace7c3950d51e9b288a83056452c61a5fac05421c139536c2747036914b7df907dc60b"
        "7fe73ba919f3eee472b95503b8f324a395e87bafe1ca682002d89a9506889184329c68c0ed596e"
        "13d70d2d8db56b23a116407031143bb3d4ac2021460a84cb49f112b08c62e3bcafc649bcce6f917"
        "49ae928b919df23409c6e1bba2034d5c3b1554a9e80eddce8ac0fc319b4ec49dc609f1ffbee294"
        "f4569f61ee8a0ba529c21c01aac5a903171773b11a74f06ccc6533799435faacf43330343a2132b6"
        "fe7e70400000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "51203a6c36818562ca3aa86741eb70dda13da67a5977255fc8af67109c8dbdd9f3ca"
    )
    spent_prevouts = ((50000, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=50000,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block31842_p2wsh_op1_only_witness_accepted():
    """
    Consensus fixture: testnet4 block 31842 tx b6dc5519… input 0 spends P2WSH whose
    witness script is only OP_1 (0x51). Valid witness stack may be [witnessScript] with
    no prior stack items (len 1), not only len >= 2.
    """
    tx_hex = (
        "020000000001064cb3e118921b7f9c596bdbc2bedce90f51681827f0a1178bf9f886b7afc1ed910100"
        "000000ffffffffdd1f095183a08874047ea84965d1cfabc7245bdf6464da99d0c1a8900999439d010000"
        "0000fdffffffe7e1468a08257f92dcd5acf06706cee50b1a9a557ad2fe6c1b30739f87a30c570000000"
        "000fdffffff8c83a62baf9222256b585cc18b6c79b46af5482dc876e5332d89dd30c40733c000000000"
        "00fdffffff4de2aabf729c9308b3400f9d734393db4b865ef02d07c3b165d40a13a2f8b796010000000"
        "0fdffffff4ba7945ac04ce5e202f2f53ca0af0287623aa386fe1976942d816c208d7b1183010000000"
        "0fdffffff0100000000000000000e6a0c00010203040506070809abba0101510140139e89c79e234849"
        "aedd5710c5260fb88a6c02d6e8780bcb41008d5792609b2c5a65c19319706d8921e91045b92ce3d445"
        "acb2d4b33e9bd2aec27d9df891e85901402bd9baf2fb0315b6371c5a5d98a87217f4e4d1cf1d1de063"
        "74c6ff26e7b0b18aefbab3dff47f4c50f960247145a23ea597cedbdf77b387891a841ac246cc51b60140"
        "7a4df0c4ac36f2dee3f8130087db54ef2952fc969290bb072727b7fbf37d41cdd1d097d69e6c04e509"
        "c7a429554a53fa5648b388fa060c1f32dce5fa9af83aca01406250d86bb69dfd5d5fa20839a2f25da733"
        "63d3993f39d2917065a68c42bc9a9d8b22b95cdcc5af313e0a3ec1889f3867e80c0e3e1f7ddf11c68fb2"
        "b0eb2329080140f4d1db91beb866731d2cd3e42cf04c6bc127035e1a1886d5a788f23baf48b06e9948e11"
        "1a71d9ecdffab865759cb4705326de4a32959264f305328ddfc90cfab00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "00204ae81572f06e1b88fd5ced7a1a000945432e83e1551e6f721ee9c00b8cc33260"
    )
    spent_prevouts = ((69179, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=69179,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block30445_p2wsh_checksigverify_ordinals_envelope_accepted():
    """
    Consensus fixture: testnet4 block 30445 tx fbfa79f1… input 0 spends P2WSH with
    witness script `<pubkey> OP_CHECKSIGVERIFY OP_0 OP_IF` Ordinals envelope; VERIFY must
    not leave a pushed true on the stack (clean-stack semantics require exactly one item).
    """
    tx_hex = (
        "02000000000101229c1b85db7e84ef2709305324e699bc584616bb3713d4ea27b1e7086933fcfa000"
        "0000000ffffffff012202000000000000225120fb988fc54350a2c4ba78b11da3789bb7430fe7426"
        "e35326d0f1122996f44a554032103091e2badb6f972cd4b3ac3abd2277aa90033befa10887f58eb"
        "864ffa6003934b473044022028ab9ddeaffa2fc64489d6f01d90a5ad3d3903e5d8e2a28ef0d407160"
        "354fc7002207b4de821fc5f17b2e62c3c069c3d1cbcf47febad539090dc41edd9d35feeb2b401552"
        "103091e2badb6f972cd4b3ac3abd2277aa90033befa10887f58eb864ffa6003934bad0063036f726"
        "4010118746578742f706c61696e3b636861727365743d7574662d38000e48656c6c6f204f726469"
        "6e616c736800000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "00206c0ca4af021f29c12a5711c36e66538c1bbb7a8bac681fd0b0a052c12bbe6e9d"
    )
    spent_prevouts = ((1000, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=1000,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block27840_bare_multisig_accepted():
    """
    Consensus fixture: testnet4 block 27840 tx f2b2a965… input 0 spends bare 2-of-3
    multisig (OP_2 + three uncompressed pubkeys + OP_3 OP_CHECKMULTISIG) with
    OP_0 dummy and two DER signatures in scriptSig.
    """
    tx_hex = (
        "010000000165d9e14560f3a2e854fd835cf525640812f1f6fd133655dd6be5db263371f4210000000093"
        "0048304502210086d2930d3e4fe31f719443f256d29de2593517438b71f2583991708d0cae8a0f022056565"
        "e31ccf5aecaf1039185968e91d6e43b23f341a92ba203c492f9b3bbd41401483045022100d2710f12e0073"
        "d5a8affe002c8ab1eb8bc84e3a0597fd8630039e4e4ad7a35e202203573226b77c8354de561db5e1929d9"
        "c3722bbfe9802d3ec5881b729b2061b05101ffffffff01bc220700000000001976a9148f8fc18a0bd6136"
        "666ea989b0f2815b49afddb0588ac00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex(
        "524104ad34a2c1bbd3aec7ebae0c3cfab37c0715ec3a189597ae31b1ed1f44abe93047e2ec7a945c2a121"
        "9484bdb458068bb8a7ce13c190325357a29424a089b8bd756410478607280574ccab25285b26d225c02988"
        "b68cf2adead05f2d21a12b3006026d6e71aa2491733c8731d4ac44be2ae5eb4552180c9d0cb29f37fb0167"
        "adb51b37e4104bf81ac047f76bd187351a9dc5ea2fead1b0de39fc367e9b6ebdcc1d877dfb2da8ec28ad50d"
        "de6732dc94bdd4f26382bac4f69cda10987b43151cb613f7e06f7653ae"
    )
    spent_prevouts = ((477645, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=477645,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block27815_p2sh_if_else_numeric_branch_accepted():
    """
    Consensus fixture: testnet4 block 27815 tx 2a691884… input 0 spends P2SH with
    OP_IF (numeric SWAP/SUB/GREATERTHAN/VERIFY branch) / OP_ELSE OP_SHA256 OP_EQUALVERIFY
    / OP_ENDIF OP_CHECKSIG. Branch selector is OP_1; operand push is 2001 vs 2024.
    """
    tx_hex = (
        "010000000143249874a2c8eaca87e81aa704f51c0ebc5f901f1fec5a231e2e132d5813c8f000000000c"
        "1483045022100e9b36a49d359651ece3329cacc8278f78a1a6d468bb22b571af87f68784f5a460220771"
        "d58102552d1abab54a060cc057859ab961f5c476207b0a295eed9851465110102d107514c726302e807"
        "7c940112a06967a8206009b3c19a19f84e6b5208493a411939d0f49a90b462aa55b5b32466602c80b488"
        "684104b7327478cf2c4d82a3d7dc3cfeb34d157dfccc0dc07d3520956266b1bb001c21668496e96dc149"
        "eef05de8eead82c6a1c3cd42aabbf27910d247d699e300a494acffffffff017c250b00000000001976a914"
        "3dc72f5ac591cfdde5fa8aec7887f2cdd87375c588ac00000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    prev_spk = bytes.fromhex("a9149bd8827378f1a7dbd6f5ace4c90ab98b706fb86287")
    spent_prevouts = ((740492, prev_spk),)
    verify_transaction_input(
        tx,
        0,
        script_pubkey=prev_spk,
        amount=740492,
        spent_prevouts=spent_prevouts,
    )


def test_real_testnet4_block25207_bare_op1_and_p2tr_spend_accepted():
    tx_hex = (
        "02000000000106b02f1f81d68f0e0dac6257a9b309ac98142eac7ec014cdb0361db35c317cf5c100000000"
        "00fdffffffc0b49ea6f7fd9943deab3416c86a120799080f8ecc70bc6a5f7816863ead6a050100000000"
        "fdffffffc0b49ea6f7fd9943deab3416c86a120799080f8ecc70bc6a5f7816863ead6a050300000000"
        "fdffffffc0b49ea6f7fd9943deab3416c86a120799080f8ecc70bc6a5f7816863ead6a050400000000"
        "fdffffffc0b49ea6f7fd9943deab3416c86a120799080f8ecc70bc6a5f7816863ead6a050200000000"
        "fdffffffc0b49ea6f7fd9943deab3416c86a120799080f8ecc70bc6a5f7816863ead6a050000000000"
        "fdffffff010000000000000000066a04deadbeef0140bf73fb4f54a861c8eff76c87d8e5338518be5c12"
        "b7d234851b9a8ebee3b99e41f5c5673fe32a319d522fc4223697e84f633f222053f1e90264e2415436"
        "bb244f000000000000000000"
    )
    payload = bytes.fromhex(tx_hex)
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    p2tr_spk = bytes.fromhex(
        "51208d957952d77b014ef71a8872c9ab00ec7615020c2616092e673fa4e47c9267b2"
    )
    bare_op1 = bytes.fromhex("51")
    spent_prevouts = (
        (725313, p2tr_spk),
        (1, bare_op1),
        (1, bare_op1),
        (1, bare_op1),
        (1, bare_op1),
        (1, bare_op1),
    )
    for input_index, (amount, script_pubkey) in enumerate(spent_prevouts):
        verify_transaction_input(
            tx,
            input_index,
            script_pubkey=script_pubkey,
            amount=amount,
            spent_prevouts=spent_prevouts,
        )


def _normalized_xonly_pubkey(secret: int) -> tuple[int, bytes]:
    pt = _scalar_mult(secret % N if secret else 1, (Gx, Gy))
    assert pt is not None
    d = secret % N if secret else 1
    if pt[1] % 2:
        d = N - d
    p2 = _scalar_mult(d, (Gx, Gy))
    assert p2 is not None and p2[1] % 2 == 0
    return d, p2[0].to_bytes(32, "big")


def test_taproot_script_path_tapscript_checksig_accepted():
    """Synthetic P2TR script-path leaf 0xc0: <32-byte pubkey> checksig spends with Schnorr tapscript sighash."""
    from pybitnode.consensus.script import interpreter as tr
    from pybitnode.consensus.script.interpreter import WITNESS_V1_TAPROOT_XONLY_PK_LEN
    from pybitnode.consensus.script.opcodes import OP_1 as OP_CODE_1, OP_CHECKSIG
    from pybitnode.consensus.secp256k1 import sign_bip340_schnorr

    secret, pk_xonly = _normalized_xonly_pubkey(1234567 % N)

    leaf_version = 0xC0
    tapscript = bytes([len(pk_xonly)]) + pk_xonly + bytes([OP_CHECKSIG])
    leaf_digest = tapleaf_hash(leaf_version, tapscript)

    parity, output_x = tr._taproot_tweak_pubkey_xonly(pk_xonly, leaf_digest)
    control_first = leaf_version | parity
    ctrl = bytes([control_first]) + pk_xonly  # leaf path empty
    prev_spk = bytes([OP_CODE_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]) + output_x

    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\xee" * 32, index=5),
                script_sig=b"",
                sequence=0xFFFFFFFD,
            ),
        ),
        outputs=(
            TxOut(value=99_998_999, script_pubkey=b"\x51"),
        ),
        lock_time=0,
    )

    amt = 100_000_000
    spent_prevouts = ((amt, prev_spk),)

    digest = taproot_signature_hash(
        unsigned,
        0,
        spent_prevouts,
        hash_type=0,
        annex=None,
        ext_flag=1,
        tapleaf_hash=leaf_digest,
        tapscript_codeseparator_pos=0xFFFFFFFF,
    )

    wit = (sign_bip340_schnorr(secret, digest), tapscript, ctrl)
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=(wit,),
    )

    verify_transaction_input(signed, 0, script_pubkey=prev_spk, amount=amt, spent_prevouts=spent_prevouts)


def test_taproot_script_path_annex_updates_spend_type():
    """Annex commits to sighash spend_type lower bit / sha_annex."""
    from pybitnode.consensus.script import interpreter as tr
    from pybitnode.consensus.script.interpreter import WITNESS_V1_TAPROOT_XONLY_PK_LEN
    from pybitnode.consensus.script.opcodes import OP_1 as OP_CODE_1, OP_CHECKSIG
    from pybitnode.consensus.script.sighash import tapleaf_hash
    from pybitnode.consensus.secp256k1 import sign_bip340_schnorr

    secret, pk_xonly = _normalized_xonly_pubkey(7654321 % N)

    leaf_version = 0xC0
    tapscript = bytes([len(pk_xonly)]) + pk_xonly + bytes([OP_CHECKSIG])
    leaf_digest = tapleaf_hash(leaf_version, tapscript)

    parity, output_x = tr._taproot_tweak_pubkey_xonly(pk_xonly, leaf_digest)
    ctrl = bytes([leaf_version | parity]) + pk_xonly

    annex = bytes([0x50, 0xAB])

    prev_spk = bytes([OP_CODE_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]) + output_x
    amt = 50_000_000
    tx_base = Transaction(
        version=2,
        inputs=(
            TxIn(previous_output=OutPoint(hash=b"\xaa" * 32, index=3), script_sig=b"", sequence=0xFFFFFFFF),
        ),
        outputs=(TxOut(value=amt - 1_000, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    spent_prevouts = ((amt, prev_spk),)

    digest_base = taproot_signature_hash(
        tx_base,
        0,
        spent_prevouts,
        hash_type=0,
        annex=None,
        ext_flag=1,
        tapleaf_hash=leaf_digest,
    )
    digest_annex = taproot_signature_hash(
        tx_base,
        0,
        spent_prevouts,
        hash_type=0,
        annex=annex,
        ext_flag=1,
        tapleaf_hash=leaf_digest,
    )
    assert digest_base != digest_annex

    sig_annex = sign_bip340_schnorr(secret, digest_annex)
    signed_annex = Transaction(
        version=tx_base.version,
        inputs=tx_base.inputs,
        outputs=tx_base.outputs,
        lock_time=tx_base.lock_time,
        witness=(
            (
                sig_annex,
                tapscript,
                ctrl,
                annex,
            ),
        ),
    )

    verify_transaction_input(
        signed_annex,
        0,
        script_pubkey=prev_spk,
        amount=amt,
        spent_prevouts=spent_prevouts,
    )


def test_taproot_unknown_leaf_accepted_without_tapscript_interpreter():
    """Non–0xc0 leaf: commitment verified then success without BIP342 execution (Core-aligned)."""
    from pybitnode.consensus.script import interpreter as tr
    from pybitnode.consensus.script.interpreter import WITNESS_V1_TAPROOT_XONLY_PK_LEN
    from pybitnode.consensus.script.opcodes import OP_1 as OP_CODE_1

    leaf_version = 0xFE
    _, pk_xonly = _normalized_xonly_pubkey(333 % N)

    tapscript = b"\xff" + b"\x00" * 200  # would be invalid tapscript semantics
    leaf_digest = tapleaf_hash(leaf_version, tapscript)
    parity, output_x = tr._taproot_tweak_pubkey_xonly(pk_xonly, leaf_digest)
    ctrl = bytes([leaf_version | parity]) + pk_xonly

    prev_spk = bytes([OP_CODE_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]) + output_x
    amt = 8_888_888
    tx = Transaction(
        version=2,
        inputs=(TxIn(previous_output=OutPoint(hash=b"\xfe" * 32, index=12), script_sig=b"", sequence=0xFFFFFFFF),),
        outputs=(TxOut(value=1000, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=(
            (
                tapscript,
                ctrl,
            ),
        ),
    )
    spent_prevouts = ((amt, prev_spk),)
    verify_transaction_input(tx, 0, script_pubkey=prev_spk, amount=amt, spent_prevouts=spent_prevouts)


def test_tapscript_merkle_mismatch_rejected():
    from pybitnode.consensus.script import interpreter as tr
    from pybitnode.consensus.script.interpreter import WITNESS_V1_TAPROOT_XONLY_PK_LEN
    from pybitnode.consensus.script.opcodes import OP_1 as OP_CODE_1, OP_CHECKSIG
    from pybitnode.consensus.secp256k1 import sign_bip340_schnorr

    secret, pk_xonly = _normalized_xonly_pubkey(444 % N)

    leaf_version = 0xC0
    tapscript = bytes([len(pk_xonly)]) + pk_xonly + bytes([OP_CHECKSIG])
    parity, correct_out = tr._taproot_tweak_pubkey_xonly(pk_xonly, tapleaf_hash(leaf_version, tapscript))

    wrong_sibling = b"\xaa" * 32
    ctrl = bytes([leaf_version | parity]) + pk_xonly + wrong_sibling
    prev_spk = bytes([OP_CODE_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]) + correct_out

    leaf_digest = tapleaf_hash(leaf_version, tapscript)
    amt = 20_000_000

    dummy_tx = Transaction(
        version=2,
        inputs=(TxIn(previous_output=OutPoint(hash=b"\xf0" * 32, index=8), script_sig=b"", sequence=0xFFFFFFFF),),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    spent_prevouts = ((amt, prev_spk),)

    digest = taproot_signature_hash(
        dummy_tx,
        0,
        spent_prevouts,
        hash_type=0,
        ext_flag=1,
        tapleaf_hash=leaf_digest,
    )
    wit = (
        sign_bip340_schnorr(secret, digest),
        tapscript,
        ctrl,
    )
    corrupt = Transaction(
        version=dummy_tx.version,
        inputs=dummy_tx.inputs,
        outputs=dummy_tx.outputs,
        lock_time=dummy_tx.lock_time,
        witness=(wit,),
    )

    with pytest.raises(ScriptVerifyError):
        verify_transaction_input(corrupt, 0, script_pubkey=prev_spk, amount=amt, spent_prevouts=spent_prevouts)


def test_secp256k1_sign_verify_roundtrip():
    from pybitnode.consensus.secp256k1 import sign_der

    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    digest = bytes.fromhex("ab" * 32)
    signature = sign_der(private_key, digest)
    assert verify_der_signature(pubkey, digest, signature)


def test_p2pk_spend_roundtrip():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey_compressed = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2pk_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey_compressed,
        output_value=49_0000_0000,
    )
    verify_transaction_input(
        signed,
        0,
        script_pubkey=script_pubkey,
        amount=50_0000_0000,
    )


def test_p2pk_uncompressed_script_template_detected():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey_uncompressed = b"\x04" + point[0].to_bytes(32, "big") + point[1].to_bytes(32, "big")
    script = p2pk_script_pubkey(pubkey_uncompressed)
    assert len(script) == 67
    assert is_p2pk(script)


def test_p2pkh_spend_roundtrip():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    verify_transaction_input(
        signed,
        0,
        script_pubkey=script_pubkey,
        amount=50_0000_0000,
    )


def test_p2wpkh_spend_roundtrip():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2wpkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    verify_transaction_input(
        signed,
        0,
        script_pubkey=script_pubkey,
        amount=50_0000_0000,
    )


def test_p2pk_compressed_script_template_detected():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey_compressed = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    script = p2pk_script_pubkey(pubkey_compressed)
    assert len(script) == 35
    assert is_p2pk(script)


def test_p2pkh_script_template_detected():
    script = p2pkh_script_pubkey(bytes.fromhex("5b6462475454710f3c22f5fdf0b40704c92f25c3"))
    assert len(script) == 25


def test_p2sh_script_template_detected():
    script = p2sh_script_pubkey(bytes.fromhex("5b6462475454710f3c22f5fdf0b40704c92f25c3"))
    assert len(script) == 23


def test_p2sh_spend_roundtrip():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2sh_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2wsh_spend_roundtrip():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2wsh_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_verify_script_rejects_bad_signature():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    bad_sig = bytearray(signed.inputs[0].script_sig)
    bad_sig[5] ^= 0xFF
    bad_tx = signed.__class__(
        version=signed.version,
        inputs=(
            signed.inputs[0].__class__(
                previous_output=signed.inputs[0].previous_output,
                script_sig=bytes(bad_sig),
                sequence=signed.inputs[0].sequence,
            ),
        ),
        outputs=signed.outputs,
        lock_time=signed.lock_time,
    )
    assert not verify_script(
        bad_tx.inputs[0].script_sig,
        script_pubkey,
        tx=bad_tx,
        input_index=0,
        amount=50_0000_0000,
        witness=(),
    )


def test_verify_transaction_input_rejects_unsupported_script():
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, _script_pubkey = make_signed_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    with pytest.raises(ScriptVerifyError, match="unsupported scriptPubKey"):
        verify_transaction_input(signed, 0, script_pubkey=b"\xac", amount=50_0000_0000)


def test_witness_program_version_detects_v0_v1_and_future_versions() -> None:
    from pybitnode.consensus.script.opcodes import OP_1

    assert witness_program_version(bytes([0x00, 0x14]) + b"\xab" * 20) == 0
    assert witness_program_version(bytes([OP_1, 0x20]) + b"\xcd" * 32) == 1
    assert witness_program_version(bytes([0x52, 0x20]) + b"\xef" * 32) == 2  # OP_2
    assert witness_program_version(b"\x51") is None
    assert witness_program_version(bytes([0x00, 0x01, 0x00])) is None  # push too short


def test_verify_transaction_input_rejects_witness_v2_program_spend() -> None:
    """Future witness versions (BIP141 v2+) are rejected before script verification."""
    program = b"\xbe" * 32
    script_pubkey = bytes([0x52, len(program)]) + program  # OP_2 + push
    assert witness_program_version(script_pubkey) == 2

    spend = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x03" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=49_0000_0000, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((b"\x01",),),
    )
    with pytest.raises(ScriptVerifyError, match="unsupported witness program version 2"):
        verify_transaction_input(spend, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_verify_transaction_input_rejects_witness_v16_program_spend() -> None:
    from pybitnode.consensus.script.opcodes import OP_16

    program = b"\xca" * 40
    script_pubkey = bytes([OP_16, len(program)]) + program
    assert witness_program_version(script_pubkey) == 16

    spend = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x04" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=1, script_pubkey=b"\x51"),),
        lock_time=0,
        witness=((program,),),
    )
    with pytest.raises(ScriptVerifyError, match="unsupported witness program version 16"):
        verify_transaction_input(spend, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_fixture_block1_coinbase_mined_to_p2pkh(block1_fixture_payload: bytes) -> None:
    block = Block.deserialize(block1_fixture_payload)
    assert is_p2pkh(block.transactions[0].outputs[0].script_pubkey)


def test_p2sh_script_pubkey_hash_mismatch_rejected() -> None:
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, _ = make_signed_p2sh_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    wrong_outer = p2sh_script_pubkey(hash160(b"\xfe" * 32))
    with pytest.raises(ScriptVerifyError):
        verify_transaction_input(signed, 0, script_pubkey=wrong_outer, amount=50_0000_0000)


def test_p2wsh_witness_program_commitment_mismatch_rejected() -> None:
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, good_spk = make_signed_p2wsh_p2pkh_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey,
        output_value=49_0000_0000,
    )
    bad_spk = bytearray(good_spk)
    bad_spk[11] ^= 0xFF
    with pytest.raises(ScriptVerifyError):
        verify_transaction_input(signed, 0, script_pubkey=bytes(bad_spk), amount=50_0000_0000)


def test_p2pk_corrupted_signature_script_rejected() -> None:
    private_key = 1
    point = _scalar_mult(private_key, (Gx, Gy))
    assert point is not None
    pubkey_compressed = bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")
    signed, script_pubkey = make_signed_p2pk_spend(
        private_key=private_key,
        prev_txid=b"\x02" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        pubkey=pubkey_compressed,
        output_value=49_0000_0000,
    )
    bad_sig = bytearray(signed.inputs[0].script_sig)
    bad_sig[-2] ^= 0xFF
    bad_tx = signed.__class__(
        version=signed.version,
        inputs=(
            signed.inputs[0].__class__(
                previous_output=signed.inputs[0].previous_output,
                script_sig=bytes(bad_sig),
                sequence=signed.inputs[0].sequence,
            ),
        ),
        outputs=signed.outputs,
        lock_time=signed.lock_time,
    )
    assert not verify_script(
        bad_tx.inputs[0].script_sig,
        script_pubkey,
        tx=bad_tx,
        input_index=0,
        amount=50_0000_0000,
        witness=(),
    )


def _compressed_pubkey(secret: int) -> bytes:
    point = _scalar_mult(secret, (Gx, Gy))
    assert point is not None
    return bytes([0x02 + (point[1] % 2)]) + point[0].to_bytes(32, "big")


def test_multisig_redeem_script_shape():
    """Documents standard m-of-n layout: OP_m <pubkeys...> OP_n OP_CHECKMULTISIG."""
    pk_a = _compressed_pubkey(1)
    pk_b = _compressed_pubkey(2)
    script = multisig_redeem_script(2, (pk_a, pk_b))
    assert script[0] == 0x52  # OP_2 required sigs
    assert script[-2] == 0x52  # OP_2 pubkeys
    assert script[-1] == 0xAE  # OP_CHECKMULTISIG


def test_p2sh_multisig_2of2_roundtrip():
    """
    Synthetic 2-of-2 P2SH multisig spend: nested redeem script with CHECKMULTISIG,
    scriptSig dummy OP_0 + two signatures + redeemScript push.
    """
    pk_a = _compressed_pubkey(1)
    pk_b = _compressed_pubkey(2)
    signed, script_pubkey = make_signed_p2sh_multisig_spend(
        private_keys=(1, 2),
        pubkeys=(pk_a, pk_b),
        required=2,
        prev_txid=b"\x03" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2wsh_multisig_2of2_roundtrip():
    """
    Native v0 P2WSH 2-of-2: witness stack is OP_0 dummy, signatures, witness script.
    """
    pk_a = _compressed_pubkey(1)
    pk_b = _compressed_pubkey(2)
    signed, script_pubkey = make_signed_p2wsh_multisig_spend(
        private_keys=(1, 2),
        pubkeys=(pk_a, pk_b),
        required=2,
        prev_txid=b"\x04" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2sh_multisig_rejects_insufficient_signatures():
    pk_a = _compressed_pubkey(1)
    pk_b = _compressed_pubkey(2)
    signed, script_pubkey = make_signed_p2sh_multisig_spend(
        private_keys=(1,),
        pubkeys=(pk_a, pk_b),
        required=2,
        prev_txid=b"\x05" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2sh_multisig_signature_order_must_match_pubkeys():
    """
    CHECKMULTISIG matches sigs to pubkeys in order; reversed sig order fails for 2-of-2.
    """
    from pybitnode.consensus.secp256k1 import sign_der
    from pybitnode.consensus.script.sighash import legacy_sighash
    from tests.script_helpers import push_data

    pk_a = _compressed_pubkey(1)
    pk_b = _compressed_pubkey(2)
    redeem = multisig_redeem_script(2, (pk_a, pk_b))
    script_pubkey = p2sh_script_pubkey(hash160(redeem))
    unsigned = Transaction(
        version=1,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=b"\x06" * 32, index=0),
                script_sig=b"",
                sequence=0xFFFFFFFF,
            ),
        ),
        outputs=(TxOut(value=49_0000_0000, script_pubkey=b"\x51"),),
        lock_time=0,
    )
    sighash = legacy_sighash(unsigned, 0, redeem, sighash_type=1)
    sig_a = sign_der(1, sighash) + bytes([1])
    sig_b = sign_der(2, sighash) + bytes([1])
    bad_script_sig = b"\x00" + push_data(sig_b) + push_data(sig_a) + push_data(redeem)
    bad_tx = Transaction(
        version=unsigned.version,
        inputs=(
            TxIn(
                previous_output=unsigned.inputs[0].previous_output,
                script_sig=bad_script_sig,
                sequence=unsigned.inputs[0].sequence,
            ),
        ),
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(bad_tx, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_cltv_redeem_script_shape():
    """Documents CLTV redeem layout: locktime OP_CLTV OP_DROP pubkey OP_CHECKSIG."""
    from pybitnode.consensus.script.opcodes import OP_CHECKLOCKTIMEVERIFY

    pk = _compressed_pubkey(1)
    script = cltv_redeem_script(100, pk)
    assert script.startswith(bytes([1, 100]))  # minimal push of 100
    assert OP_CHECKLOCKTIMEVERIFY in script
    assert script[-1] == 0xAC  # OP_CHECKSIG


def test_p2sh_cltv_roundtrip():
    """Synthetic P2SH spend gated by OP_CHECKLOCKTIMEVERIFY (BIP65 height lock)."""
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2sh_cltv_spend(
        private_key=1,
        pubkey=pk,
        locktime_value=100,
        tx_lock_time=100,
        input_sequence=0xFFFFFFFE,
        prev_txid=b"\x07" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_real_testnet4_block38191_p2sh_cltv_version1_noop_accepted():
    """
    Consensus fixture: testnet4 block 38191 input 0 spends a P2SH redeem script
    `30000 OP_CHECKLOCKTIMEVERIFY OP_DROP <pubkey> OP_CHECKSIG` from tx version 1.
    BIP65 CLTV must no-op for nVersion < 2; the signature still independently verifies.
    """
    payload = _fixture_hex("tx_p2sh_cltv_38191.hex")
    tx, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)
    assert hash256(tx.serialize())[::-1].hex() == "4e477ff4e1a12fd78e76fb7dec0d0fcd6fb0372f757fabceb83fdb041c6ee9b6"
    assert tx.version == 1
    assert tx.lock_time == 30000
    assert tx.inputs[0].sequence == 545

    script_pubkey = _fixture_hex("tx_p2sh_cltv_38191_prev_spk.hex")
    verify_transaction_input(tx, 0, script_pubkey=script_pubkey, amount=10_000)


def test_real_testnet4_block38191_p2sh_cltv_rejects_tampered_signature():
    payload = _fixture_hex("tx_p2sh_cltv_38191.hex")
    base, consumed = Transaction.deserialize(payload)
    assert consumed == len(payload)

    script_sig = bytearray(base.inputs[0].script_sig)
    script_sig[10] ^= 0x01
    tampered = Transaction(
        version=base.version,
        inputs=(
            TxIn(
                previous_output=base.inputs[0].previous_output,
                script_sig=bytes(script_sig),
                sequence=base.inputs[0].sequence,
            ),
        ),
        outputs=base.outputs,
        lock_time=base.lock_time,
    )

    script_pubkey = _fixture_hex("tx_p2sh_cltv_38191_prev_spk.hex")
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(tampered, 0, script_pubkey=script_pubkey, amount=10_000)


def test_p2wsh_cltv_roundtrip():
    """Native v0 P2WSH witness script with OP_CHECKLOCKTIMEVERIFY."""
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2wsh_cltv_spend(
        private_key=1,
        pubkey=pk,
        locktime_value=100,
        tx_lock_time=100,
        input_sequence=0xFFFFFFFE,
        prev_txid=b"\x08" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2sh_cltv_rejects_unsatisfied_locktime():
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2sh_cltv_spend(
        private_key=1,
        pubkey=pk,
        locktime_value=200,
        tx_lock_time=100,
        input_sequence=0xFFFFFFFE,
        prev_txid=b"\x09" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2sh_csv_roundtrip():
    """Synthetic P2SH spend gated by OP_CHECKSEQUENCEVERIFY (BIP112 block relative lock)."""
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2sh_csv_spend(
        private_key=1,
        pubkey=pk,
        csv_operand=10,
        input_sequence=10,
        prev_txid=b"\x0A" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2wsh_csv_roundtrip():
    """Native v0 P2WSH witness script with OP_CHECKSEQUENCEVERIFY."""
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2wsh_csv_spend(
        private_key=1,
        pubkey=pk,
        csv_operand=10,
        input_sequence=10,
        prev_txid=b"\x0B" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def test_p2sh_csv_rejects_insufficient_sequence():
    pk = _compressed_pubkey(1)
    signed, script_pubkey = make_signed_p2sh_csv_spend(
        private_key=1,
        pubkey=pk,
        csv_operand=20,
        input_sequence=10,
        prev_txid=b"\x0C" * 32,
        prev_vout=0,
        prev_amount=50_0000_0000,
        output_value=49_0000_0000,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(signed, 0, script_pubkey=script_pubkey, amount=50_0000_0000)


def _tapscript_cltv_or_csv_spend(
    *,
    secret: int,
    pk_xonly: bytes,
    tapscript: bytes,
    lock_time: int,
    sequence: int,
    prev_hash: bytes,
) -> tuple[Transaction, bytes, tuple[tuple[int, bytes], ...]]:
    """Build signed P2TR script-path spend for a tapscript with Schnorr sighash."""
    from pybitnode.consensus.script import interpreter as tr
    from pybitnode.consensus.script.interpreter import WITNESS_V1_TAPROOT_XONLY_PK_LEN
    from pybitnode.consensus.script.opcodes import OP_1 as OP_CODE_1
    from pybitnode.consensus.secp256k1 import sign_bip340_schnorr

    leaf_version = 0xC0
    leaf_digest = tapleaf_hash(leaf_version, tapscript)
    parity, output_x = tr._taproot_tweak_pubkey_xonly(pk_xonly, leaf_digest)
    ctrl = bytes([leaf_version | parity]) + pk_xonly
    prev_spk = bytes([OP_CODE_1, WITNESS_V1_TAPROOT_XONLY_PK_LEN]) + output_x

    unsigned = Transaction(
        version=2,
        inputs=(
            TxIn(
                previous_output=OutPoint(hash=prev_hash, index=0),
                script_sig=b"",
                sequence=sequence,
            ),
        ),
        outputs=(TxOut(value=99_998_999, script_pubkey=b"\x51"),),
        lock_time=lock_time,
    )
    amt = 100_000_000
    spent_prevouts = ((amt, prev_spk),)
    digest = taproot_signature_hash(
        unsigned,
        0,
        spent_prevouts,
        hash_type=0,
        annex=None,
        ext_flag=1,
        tapleaf_hash=leaf_digest,
        tapscript_codeseparator_pos=0xFFFFFFFF,
    )
    signed = Transaction(
        version=unsigned.version,
        inputs=unsigned.inputs,
        outputs=unsigned.outputs,
        lock_time=unsigned.lock_time,
        witness=((sign_bip340_schnorr(secret, digest), tapscript, ctrl),),
    )
    return signed, prev_spk, spent_prevouts


def test_taproot_script_path_tapscript_cltv_accepted():
    """Synthetic P2TR script-path: locktime OP_CLTV OP_DROP xonly checksig (BIP342)."""
    from pybitnode.consensus.script.opcodes import OP_CHECKLOCKTIMEVERIFY, OP_CHECKSIG, OP_DROP
    from tests.script_helpers import push_script_num

    secret, pk_xonly = _normalized_xonly_pubkey(7654321 % N)
    locktime_value = 100
    tapscript = (
        push_script_num(locktime_value)
        + bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP, len(pk_xonly)])
        + pk_xonly
        + bytes([OP_CHECKSIG])
    )
    signed, prev_spk, spent_prevouts = _tapscript_cltv_or_csv_spend(
        secret=secret,
        pk_xonly=pk_xonly,
        tapscript=tapscript,
        lock_time=locktime_value,
        sequence=0xFFFFFFFE,
        prev_hash=b"\x0D" * 32,
    )
    verify_transaction_input(
        signed, 0, script_pubkey=prev_spk, amount=100_000_000, spent_prevouts=spent_prevouts
    )


def test_taproot_script_path_tapscript_cltv_rejects_unsatisfied_locktime():
    from pybitnode.consensus.script.opcodes import OP_CHECKLOCKTIMEVERIFY, OP_CHECKSIG, OP_DROP
    from tests.script_helpers import push_script_num

    secret, pk_xonly = _normalized_xonly_pubkey(8765432 % N)
    tapscript = (
        push_script_num(200)
        + bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP, len(pk_xonly)])
        + pk_xonly
        + bytes([OP_CHECKSIG])
    )
    signed, prev_spk, spent_prevouts = _tapscript_cltv_or_csv_spend(
        secret=secret,
        pk_xonly=pk_xonly,
        tapscript=tapscript,
        lock_time=100,
        sequence=0xFFFFFFFE,
        prev_hash=b"\x0E" * 32,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(
            signed, 0, script_pubkey=prev_spk, amount=100_000_000, spent_prevouts=spent_prevouts
        )


def test_taproot_script_path_tapscript_csv_accepted():
    """Synthetic P2TR script-path: sequence OP_CSV OP_DROP xonly checksig (BIP342)."""
    from pybitnode.consensus.script.opcodes import OP_CHECKSEQUENCEVERIFY, OP_CHECKSIG, OP_DROP
    from tests.script_helpers import push_script_num

    secret, pk_xonly = _normalized_xonly_pubkey(9876543 % N)
    csv_operand = 10
    tapscript = (
        push_script_num(csv_operand)
        + bytes([OP_CHECKSEQUENCEVERIFY, OP_DROP, len(pk_xonly)])
        + pk_xonly
        + bytes([OP_CHECKSIG])
    )
    signed, prev_spk, spent_prevouts = _tapscript_cltv_or_csv_spend(
        secret=secret,
        pk_xonly=pk_xonly,
        tapscript=tapscript,
        lock_time=0,
        sequence=csv_operand,
        prev_hash=b"\x0F" * 32,
    )
    verify_transaction_input(
        signed, 0, script_pubkey=prev_spk, amount=100_000_000, spent_prevouts=spent_prevouts
    )


def test_taproot_script_path_tapscript_csv_rejects_insufficient_sequence():
    from pybitnode.consensus.script.opcodes import OP_CHECKSEQUENCEVERIFY, OP_CHECKSIG, OP_DROP
    from tests.script_helpers import push_script_num

    secret, pk_xonly = _normalized_xonly_pubkey(1112223 % N)
    tapscript = (
        push_script_num(20)
        + bytes([OP_CHECKSEQUENCEVERIFY, OP_DROP, len(pk_xonly)])
        + pk_xonly
        + bytes([OP_CHECKSIG])
    )
    signed, prev_spk, spent_prevouts = _tapscript_cltv_or_csv_spend(
        secret=secret,
        pk_xonly=pk_xonly,
        tapscript=tapscript,
        lock_time=0,
        sequence=10,
        prev_hash=b"\x10" * 32,
    )
    with pytest.raises(ScriptVerifyError, match="script verification failed"):
        verify_transaction_input(
            signed, 0, script_pubkey=prev_spk, amount=100_000_000, spent_prevouts=spent_prevouts
        )
