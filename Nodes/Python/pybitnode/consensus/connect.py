from __future__ import annotations

from dataclasses import dataclass, field
from os import environ
from time import perf_counter

from pybitnode.chain.params import ChainParams
from pybitnode.consensus.constants import COINBASE_MATURITY
from pybitnode.consensus.block import Block
from pybitnode.consensus.coinbase import (
    CoinbaseError,
    is_spendable_output,
    validate_bip34_height,
)
from pybitnode.consensus.merkle import transaction_txid
from pybitnode.consensus.script.script_verify_runner import (
    InputVerifyTask,
    ScriptVerifyBatchError,
    ScriptVerifyRunner,
    verify_inputs,
)
from pybitnode.consensus.subsidy import block_subsidy
from pybitnode.consensus.witness import validate_witness_commitment
from pybitnode.chainstate.tracker import ProjectTracker
from pybitnode.metrics import META_BLOCKS_VALIDATED_TOTAL, incr_meta_counter
from pybitnode.messages.transaction import OutPoint, Transaction


class ConnectBlockError(ValueError):
    pass


@dataclass(frozen=True)
class _PrevoutInfo:
    value: int
    script_pubkey: bytes
    coinbase: bool
    height: int


def _sync_timing_enabled() -> bool:
    return environ.get("SYNC_TIMING", "").strip().lower() in {"1", "true", "yes", "on"}


def _record_connect_timing(
    tracker: ProjectTracker,
    *,
    height: int,
    block: Block,
    timings: dict[str, float],
    success: bool = True,
    error: str = "",
) -> None:
    details = {
        "height": height,
        "block_hash": block.header.block_hash_hex(),
        "tx_count": len(block.transactions),
        "input_count": sum(len(tx.inputs) for tx in block.transactions if not tx.is_coinbase),
        "success": success,
        "error": error,
        "stages_ms": {key: round(value * 1000, 3) for key, value in sorted(timings.items())},
    }
    tracker.log_event("timing", "connect_block", details=details)


def _external_spend_undo_entries(view: _BlockUtxoView) -> list[dict]:
    """Snapshot prevouts spent from the persisted UTXO set (excludes same-block internal moves)."""
    entries: list[dict] = []
    for txid, vout in view.spent:
        if (txid, vout) in view.created:
            continue
        utxo = view.external_loaded.get((txid, vout))
        if utxo is None:
            utxo = view.tracker.get_utxo(txid, vout)
        if utxo is None:
            raise ConnectBlockError(
                "internal error: could not capture undo for "
                f"{txid[::-1].hex()}:{vout}"
            )
        entries.append(
            {
                "txid": utxo["txid"],
                "vout": int(utxo["vout"]),
                "height": int(utxo["height"]),
                "value": int(utxo["value"]),
                "script_pubkey": utxo["script_pubkey"],
                "coinbase": int(utxo["coinbase"]),
            }
        )
    return entries


@dataclass
class _BlockUtxoView:
    tracker: ProjectTracker
    height: int
    created: dict[tuple[bytes, int], dict] = field(default_factory=dict)
    spent: set[tuple[bytes, int]] = field(default_factory=set)
    external_loaded: dict[tuple[bytes, int], dict | None] = field(default_factory=dict)
    timings: dict[str, float] | None = None

    def get(self, outpoint: OutPoint) -> dict | None:
        key = (outpoint.hash, outpoint.index)
        if key in self.spent:
            return None
        if key in self.created:
            return self.created[key]
        if key not in self.external_loaded:
            started = perf_counter() if self.timings is not None else 0.0
            self.external_loaded[key] = self.tracker.get_utxo(outpoint.hash, outpoint.index)
            if self.timings is not None:
                self.timings["utxo_load"] = self.timings.get("utxo_load", 0.0) + (perf_counter() - started)
        return self.external_loaded[key]

    def spend(self, outpoint: OutPoint) -> dict:
        key = (outpoint.hash, outpoint.index)
        if key in self.spent:
            raise ConnectBlockError(
                f"double spend of {outpoint.hash[::-1].hex()}:{outpoint.index}"
            )
        utxo = self.get(outpoint)
        if utxo is None:
            raise ConnectBlockError(
                f"missing UTXO {outpoint.hash[::-1].hex()}:{outpoint.index}"
            )
        if utxo["coinbase"] and self.height - int(utxo["height"]) < COINBASE_MATURITY:
            raise ConnectBlockError(
                f"coinbase output not mature at height {self.height} (created at {utxo['height']})"
            )
        self.spent.add(key)
        return utxo

    def create(
        self,
        txid: bytes,
        vout: int,
        *,
        value: int,
        script_pubkey: bytes,
        coinbase: bool,
    ) -> None:
        key = (txid, vout)
        if key in self.created:
            raise ConnectBlockError(f"duplicate UTXO {txid[::-1].hex()}:{vout}")
        if key in self.external_loaded:
            if self.external_loaded[key] is not None:
                raise ConnectBlockError(f"duplicate UTXO {txid[::-1].hex()}:{vout}")
        else:
            started = perf_counter() if self.timings is not None else 0.0
            existing = self.tracker.get_utxo(txid, vout)
            if self.timings is not None:
                self.timings["utxo_load"] = self.timings.get("utxo_load", 0.0) + (perf_counter() - started)
            if existing is not None:
                self.external_loaded[key] = existing
                raise ConnectBlockError(f"duplicate UTXO {txid[::-1].hex()}:{vout}")
            self.external_loaded[key] = None
        self.created[key] = {
            "txid": txid[::-1].hex(),
            "vout": vout,
            "height": self.height,
            "value": value,
            "script_pubkey": script_pubkey.hex(),
            "coinbase": 1 if coinbase else 0,
        }

    def apply(self) -> None:
        external_spends = [(txid, vout) for txid, vout in self.spent if (txid, vout) not in self.created]
        self.tracker.spend_utxos(external_spends)
        unspent_created = [
            utxo
            for key, utxo in self.created.items()
            if key not in self.spent
        ]
        self.tracker.add_utxos(unspent_created)


def _validate_coinbase(coinbase: Transaction, height: int, *, total_fees: int) -> None:
    try:
        validate_bip34_height(coinbase, height)
    except CoinbaseError as exc:
        raise ConnectBlockError(str(exc)) from exc

    subsidy = block_subsidy(height)
    allowed = subsidy + total_fees
    output_total = sum(output.value for output in coinbase.outputs)
    if output_total > allowed:
        raise ConnectBlockError(
            f"coinbase value {output_total} exceeds subsidy+fees {allowed} at height {height}"
        )


def _block_has_witness(block: Block) -> bool:
    return any(tx.witness for tx in block.transactions)


def _validate_non_coinbase_inputs(
    view: _BlockUtxoView,
    tx: Transaction,
    timings: dict[str, float] | None = None,
    script_verify_runner: ScriptVerifyRunner | None = None,
) -> int:
    seen_prevouts: set[tuple[bytes, int]] = set()
    prevout_infos: list[_PrevoutInfo] = []
    for tx_in in tx.inputs:
        outpoint = tx_in.previous_output
        key = (outpoint.hash, outpoint.index)
        if key in seen_prevouts:
            raise ConnectBlockError(f"double spend of {outpoint.hash[::-1].hex()}:{outpoint.index}")
        seen_prevouts.add(key)

        utxo = view.get(outpoint)
        if utxo is None:
            raise ConnectBlockError(f"missing UTXO {outpoint.hash[::-1].hex()}:{outpoint.index}")
        if utxo["coinbase"] and view.height - int(utxo["height"]) < COINBASE_MATURITY:
            raise ConnectBlockError(
                f"coinbase output not mature at height {view.height} (created at {utxo['height']})"
            )
        prevout_infos.append(
            _PrevoutInfo(
                value=int(utxo["value"]),
                script_pubkey=bytes.fromhex(utxo["script_pubkey"]),
                coinbase=bool(utxo["coinbase"]),
                height=int(utxo["height"]),
            )
        )

    spent_prevouts = tuple(
        (entry.value, entry.script_pubkey) for entry in prevout_infos
    )

    input_total = 0
    verify_tasks: list[InputVerifyTask] = []
    for input_index, _tx_in in enumerate(tx.inputs):
        prevout = prevout_infos[input_index]
        verify_tasks.append(
            InputVerifyTask(
                input_index=input_index,
                script_pubkey=prevout.script_pubkey,
                amount=prevout.value,
            )
        )
        input_total += prevout.value

    try:
        if script_verify_runner is None:
            elapsed = verify_inputs(tx, spent_prevouts, verify_tasks)
        else:
            elapsed = script_verify_runner.verify_inputs(tx, spent_prevouts, verify_tasks)
        if timings is not None:
            timings["script_verify"] = timings.get("script_verify", 0.0) + elapsed
    except ScriptVerifyBatchError as exc:
        if timings is not None:
            timings["script_verify"] = timings.get("script_verify", 0.0) + exc.elapsed_seconds
        raise ConnectBlockError(str(exc)) from exc

    for tx_in in tx.inputs:
        view.spend(tx_in.previous_output)

    return input_total


def connect_block(
    tracker: ProjectTracker,
    payload: bytes,
    *,
    height: int,
    expected_prev: bytes,
    expected_hash: bytes | None = None,
    chain_name: str = "testnet4",
) -> Block:
    from pybitnode.sync.validate import BlockValidationError, validate_block

    timing_enabled = _sync_timing_enabled()
    timings: dict[str, float] | None = {"utxo_load": 0.0, "script_verify": 0.0} if timing_enabled else None
    connect_started = perf_counter() if timing_enabled else 0.0

    if height != tracker.get_validated_height(chain_name) + 1:
        raise ConnectBlockError(
            f"cannot connect height {height} on top of validated tip "
            f"{tracker.get_validated_height(chain_name)}"
        )

    try:
        block = validate_block(payload, expected_prev=expected_prev, expected_hash=expected_hash)
    except BlockValidationError as exc:
        raise ConnectBlockError(str(exc)) from exc

    try:
        with ScriptVerifyRunner() as script_verify_runner:
            view = _BlockUtxoView(tracker, height, timings=timings)
            total_fees = 0
            for tx in block.transactions:
                if tx.is_coinbase:
                    continue
                input_total = _validate_non_coinbase_inputs(
                    view,
                    tx,
                    timings=timings,
                    script_verify_runner=script_verify_runner,
                )
                output_total = sum(output.value for output in tx.outputs)
                if input_total < output_total:
                    raise ConnectBlockError("transaction outputs exceed inputs")
                total_fees += input_total - output_total
                txid = transaction_txid(tx)
                for index, output in enumerate(tx.outputs):
                    if not is_spendable_output(output.script_pubkey):
                        continue
                    view.create(
                        txid,
                        index,
                        value=output.value,
                        script_pubkey=output.script_pubkey,
                        coinbase=False,
                    )

        coinbase = block.transactions[0]
        _validate_coinbase(coinbase, height, total_fees=total_fees)
        if _block_has_witness(block):
            try:
                validate_witness_commitment(coinbase, list(block.transactions))
            except ValueError as exc:
                raise ConnectBlockError(str(exc)) from exc

        coinbase_txid = transaction_txid(coinbase)
        for index, output in enumerate(coinbase.outputs):
            if not is_spendable_output(output.script_pubkey):
                continue
            view.create(
                coinbase_txid,
                index,
                value=output.value,
                script_pubkey=output.script_pubkey,
                coinbase=True,
            )

        undo_entries = _external_spend_undo_entries(view)
        commit_started = perf_counter() if timing_enabled else 0.0
        with tracker.transaction():
            tracker.replace_utxo_undo(chain_name, height, undo_entries)
            apply_started = perf_counter() if timing_enabled else 0.0
            view.apply()
            if timings is not None:
                timings["utxo_apply"] = perf_counter() - apply_started
            tracker.set_validated_tip(height, block.header.block_hash_hex(), chain=chain_name)
            incr_meta_counter(tracker, META_BLOCKS_VALIDATED_TOTAL)
        if timings is not None:
            timings["commit"] = perf_counter() - commit_started
            timings["block_connect_store_commit"] = perf_counter() - connect_started
            _record_connect_timing(tracker, height=height, block=block, timings=timings)
        return block
    except ConnectBlockError as exc:
        if timings is not None:
            timings.setdefault("utxo_apply", 0.0)
            timings.setdefault("commit", 0.0)
            timings["block_connect_store_commit"] = perf_counter() - connect_started
            _record_connect_timing(
                tracker,
                height=height,
                block=block,
                timings=timings,
                success=False,
                error=str(exc),
            )
        raise


def disconnect_block(
    tracker: ProjectTracker,
    height: int,
    chain: ChainParams,
) -> None:
    """Reverse one validated block: restore external prevouts, drop outputs created here, rewind tip."""
    chain_name = chain.name
    validated = tracker.get_validated_height(chain_name)
    if validated != height:
        raise ConnectBlockError(
            f"cannot disconnect height {height}: validated tip is {validated}"
        )
    if height < 1:
        raise ConnectBlockError("cannot disconnect genesis (height < 1)")
    prev_hash_hex = tracker.get_header_hash(height - 1)
    if prev_hash_hex is None:
        raise ConnectBlockError(f"missing header at height {height - 1}")
    try:
        undo_entries = tracker.take_utxo_undo(chain_name, height)
    except KeyError as exc:
        raise ConnectBlockError(
            f"missing UTXO undo data for height {height}; reconnect this block or replay the chain "
            "(undo is recorded during connect)"
        ) from exc
    tracker.delete_utxos_created_at_height(height)
    for entry in undo_entries:
        tracker.add_utxo(
            bytes.fromhex(entry["txid"])[::-1],
            int(entry["vout"]),
            height=int(entry["height"]),
            value=int(entry["value"]),
            script_pubkey=bytes.fromhex(entry["script_pubkey"]),
            coinbase=bool(entry["coinbase"]),
        )
    tracker.set_validated_tip(height - 1, prev_hash_hex, chain=chain_name)
