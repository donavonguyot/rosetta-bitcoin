from __future__ import annotations

from collections.abc import Sequence

from pybitnode.consensus.script.interpreter import (
    is_bare_multisig,
    is_bare_op_n,
    is_bare_legacy_script,
    is_p2pk,
    is_p2pkh,
    is_p2sh,
    is_p2tr,
    is_p2wpkh,
    is_p2wsh,
    verify_script,
    witness_program_version,
)
from pybitnode.messages.transaction import Transaction


class ScriptVerifyError(ValueError):
    pass


def verify_transaction_input(
    transaction: Transaction,
    input_index: int,
    *,
    script_pubkey: bytes,
    amount: int,
    spent_prevouts: Sequence[tuple[int, bytes]] | None = None,
) -> None:
    if input_index >= len(transaction.inputs):
        raise ScriptVerifyError("input index out of range")

    tx_in = transaction.inputs[input_index]
    if transaction.witness and input_index < len(transaction.witness):
        witness = transaction.witness[input_index]
    else:
        witness = ()

    witness_version = witness_program_version(script_pubkey)
    if witness_version is not None and witness_version > 1:
        raise ScriptVerifyError(f"unsupported witness program version {witness_version}")

    known_template = (
        is_p2pk(script_pubkey)
        or is_p2pkh(script_pubkey)
        or is_p2wpkh(script_pubkey)
        or is_p2sh(script_pubkey)
        or is_p2wsh(script_pubkey)
        or is_p2tr(script_pubkey)
        or is_bare_op_n(script_pubkey)
        or is_bare_multisig(script_pubkey)
        or is_bare_legacy_script(script_pubkey)
    )
    if not known_template and witness_version != 1:
        raise ScriptVerifyError("unsupported scriptPubKey template")

    if not verify_script(
        tx_in.script_sig,
        script_pubkey,
        tx=transaction,
        input_index=input_index,
        amount=amount,
        witness=witness,
        spent_prevouts=spent_prevouts,
    ):
        raise ScriptVerifyError(f"script verification failed for input {input_index}")
