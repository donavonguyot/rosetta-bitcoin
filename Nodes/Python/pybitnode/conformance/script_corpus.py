from __future__ import annotations

import argparse
import json
import platform
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pybitnode.consensus.script.verify import ScriptVerifyError, verify_transaction_input
from pybitnode.messages.transaction import Transaction


@dataclass(frozen=True)
class ScriptCorpusCase:
    fixture_id: str
    height: int
    txid: str
    input_index: int
    required_rules: tuple[str, ...]
    expected_result: str
    missing_rule: str
    transaction: Transaction
    script_pubkey: bytes
    amount: int
    spent_prevouts: tuple[tuple[int, bytes], ...]


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Shared").exists() and (parent / "Nodes" / "Python").exists():
            return parent
    raise RuntimeError("could not locate repository root")


def default_manifest_path() -> Path:
    return repo_root() / "Nodes/Shared/conformance/fixtures/scripts/manifest.json"


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    manifest_path = path or default_manifest_path()
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def _first_path(entry: dict[str, Any], category: str) -> Path | None:
    values = entry.get("files", {}).get(category, [])
    if not values:
        return None
    return default_manifest_path().parent / values[0]


def _read_hex(path: Path) -> bytes:
    return bytes.fromhex(path.read_text(encoding="ascii").strip())


def _prevout_tuple(prevout: dict[str, Any]) -> tuple[int, bytes]:
    amount = prevout.get("amount", prevout.get("amount_sats", prevout.get("value")))
    spk = prevout.get("spk", prevout.get("script_pubkey", prevout.get("scriptPubKey")))
    if amount is None or spk is None:
        raise ValueError(f"prevout is missing amount or scriptPubKey: {prevout}")
    return int(amount), bytes.fromhex(str(spk))


def _spent_prevouts(entry: dict[str, Any]) -> tuple[tuple[int, bytes], ...]:
    prevouts_path = _first_path(entry, "prevouts")
    if prevouts_path is not None:
        prevouts = json.loads(prevouts_path.read_text(encoding="utf-8"))
        if not isinstance(prevouts, list):
            raise ValueError(f"prevouts must be a list for {entry['fixture_id']}")
        return tuple(_prevout_tuple(prevout) for prevout in prevouts)

    amount = entry.get("prev_amount_sats")
    spk_hex = entry.get("spent_script_pubkey")
    prev_spk_path = _first_path(entry, "prev_spk")
    if prev_spk_path is not None:
        spk_hex = prev_spk_path.read_text(encoding="ascii").strip()
    if amount is None or not spk_hex:
        raise ValueError(f"fixture has no usable prevout data: {entry['fixture_id']}")
    return ((int(amount), bytes.fromhex(str(spk_hex))),)


def _target_prevout(entry: dict[str, Any], fallback: tuple[int, bytes] | None = None) -> tuple[int, bytes]:
    amount = entry.get("prev_amount_sats")
    spk_hex = entry.get("spent_script_pubkey")
    prev_spk_path = _first_path(entry, "prev_spk")
    if prev_spk_path is not None:
        spk_hex = prev_spk_path.read_text(encoding="ascii").strip()
    if amount is not None and spk_hex:
        return int(amount), bytes.fromhex(str(spk_hex))
    if fallback is not None:
        return fallback
    raise ValueError(f"fixture has no usable target prevout data: {entry['fixture_id']}")


def _align_spent_prevouts(
    entry: dict[str, Any],
    tx: Transaction,
    spent_prevouts: tuple[tuple[int, bytes], ...],
) -> tuple[tuple[int, bytes], ...]:
    input_index = int(entry["input_index"])
    if len(spent_prevouts) == len(tx.inputs):
        return spent_prevouts
    fallback = spent_prevouts[0] if spent_prevouts else None
    target = _target_prevout(entry, fallback)
    aligned = list(spent_prevouts)
    while len(aligned) < len(tx.inputs):
        aligned.append((0, b""))
    aligned[input_index] = target
    return tuple(aligned)


def load_case(entry: dict[str, Any]) -> ScriptCorpusCase:
    tx_path = _first_path(entry, "tx")
    if tx_path is None:
        raise ValueError(f"fixture has no transaction file: {entry['fixture_id']}")
    payload = _read_hex(tx_path)
    tx, consumed = Transaction.deserialize(payload)
    if consumed != len(payload):
        raise ValueError(f"transaction parser consumed {consumed} of {len(payload)} bytes for {entry['fixture_id']}")

    input_index = int(entry["input_index"])
    spent_prevouts = _align_spent_prevouts(entry, tx, _spent_prevouts(entry))
    if input_index >= len(spent_prevouts):
        raise ValueError(f"fixture input_index {input_index} has no matching prevout: {entry['fixture_id']}")
    amount, script_pubkey = spent_prevouts[input_index]

    return ScriptCorpusCase(
        fixture_id=str(entry["fixture_id"]),
        height=int(entry["height"]),
        txid=str(entry["txid"]),
        input_index=input_index,
        required_rules=tuple(str(rule) for rule in entry.get("required_rules", [])),
        expected_result=str(entry.get("expected_result", "valid")),
        missing_rule=str(entry.get("missing_rule", "")),
        transaction=tx,
        script_pubkey=script_pubkey,
        amount=amount,
        spent_prevouts=spent_prevouts,
    )


def load_cases(*, manifest_path: Path | None = None) -> list[ScriptCorpusCase]:
    manifest = load_manifest(manifest_path)
    cases: list[ScriptCorpusCase] = []
    for entry in manifest.get("fixtures", []):
        cases.append(load_case(entry))
    return cases


def verify_case(case: ScriptCorpusCase) -> None:
    if case.expected_result != "valid":
        raise ValueError(f"unsupported expected result for {case.fixture_id}: {case.expected_result}")
    verify_transaction_input(
        case.transaction,
        case.input_index,
        script_pubkey=case.script_pubkey,
        amount=case.amount,
        spent_prevouts=case.spent_prevouts,
    )


def run_case(case: ScriptCorpusCase) -> dict[str, Any]:
    try:
        verify_case(case)
    except Exception as error:  # Results are evidence; preserve precise failures.
        return {
            "fixture_id": case.fixture_id,
            "result": "failed",
            "height": case.height,
            "txid": case.txid,
            "input_index": case.input_index,
            "required_rules": list(case.required_rules),
            "missing_rule": case.missing_rule,
            "failure": str(error),
            "failure_type": type(error).__name__,
        }
    return {
        "fixture_id": case.fixture_id,
        "result": "passed",
        "height": case.height,
        "txid": case.txid,
        "input_index": case.input_index,
        "required_rules": list(case.required_rules),
        "missing_rule": case.missing_rule,
        "failure": "",
        "failure_type": "",
    }


def git_commit() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo_root(), text=True).strip()
    except Exception:
        return ""


def run_corpus(*, manifest_path: Path | None = None) -> dict[str, Any]:
    cases = load_cases(manifest_path=manifest_path)
    results = [run_case(case) for case in cases]
    passed = sum(1 for result in results if result["result"] == "passed")
    failed = sum(1 for result in results if result["result"] == "failed")
    return {
        "implementation": "PythonNode",
        "category": "script_corpus",
        "runtime_surface": "host",
        "captured_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "commit": git_commit(),
        "python_version": platform.python_version(),
        "manifest": str((manifest_path or default_manifest_path()).relative_to(repo_root())),
        "fixture_count": len(results),
        "passed": passed,
        "failed": failed,
        "result": "passed" if failed == 0 else "failed",
        "results": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run Python against the Shared script corpus.")
    parser.add_argument("--manifest", default="")
    parser.add_argument(
        "--result-path",
        default=str(repo_root() / "Nodes/Shared/conformance/results/python_script_corpus_2026-06-03.json"),
    )
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest) if args.manifest else None
    result = run_corpus(manifest_path=manifest_path)
    out = Path(args.result_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in ("fixture_count", "passed", "failed", "result")}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
