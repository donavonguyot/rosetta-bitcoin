#!/usr/bin/env python3
"""Promote Java-cleared script fixtures into the Shared corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = ("height", "block_hash", "txid", "input_index")


def repo_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        if (parent / "Nodes" / "Java").exists() and (parent / "Nodes" / "Shared").exists():
            return parent
    raise SystemExit("could not locate repository root")


def fixture_id_for(meta_path: Path) -> str:
    stem = meta_path.stem
    if not stem.endswith("_meta"):
        raise ValueError(f"unexpected meta filename: {meta_path.name}")
    base = stem[: -len("_meta")]
    if base.startswith("tx_"):
        base = base[3:]
    clean = re.sub(r"[^a-zA-Z0-9_]+", "_", base).strip("_").lower()
    return f"scripts.{clean}"


def source_prefix(meta_path: Path) -> str:
    return meta_path.stem[: -len("_meta")]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def related_files(fixtures_dir: Path, meta_path: Path, meta: dict[str, Any]) -> list[Path]:
    prefix = source_prefix(meta_path)
    files = set(fixtures_dir.glob(f"{prefix}*"))
    height = meta.get("height")
    if isinstance(height, int):
        block = fixtures_dir / f"block_{height}.hex"
        if block.exists():
            files.add(block)
    files.add(meta_path)
    return sorted(files, key=lambda p: p.name)


def classify(path: Path, prefix: str, meta_path: Path) -> str:
    name = path.name
    if path == meta_path:
        return "meta"
    if name.startswith("block_"):
        return "block"
    if name == f"{prefix}.hex":
        return "tx"
    if "prevouts" in name:
        return "prevouts"
    if "prev_spk" in name:
        return "prev_spk"
    if "scriptsig" in name:
        return "scriptsig"
    if "redeem_script" in name or name.endswith("_redeem.hex"):
        return "redeem_script"
    if "witness_script" in name:
        return "witness_script"
    if "witness" in name:
        return "witness"
    if "tapscript" in name:
        return "tapscript"
    if "control_block" in name:
        return "control_block"
    return "aux"


def required_rules(meta: dict[str, Any], fixture_id: str) -> list[str]:
    tokens: set[str] = set()
    template = str(meta.get("template", "")).lower()
    if template:
        tokens.add(template)

    text = " ".join(
        str(meta.get(key, ""))
        for key in (
            "missing_rule",
            "redeem_script_opcode_sequence",
            "witness_script_asm",
            "tapscript_opcode_sequence",
            "java_blocker",
            "template",
        )
    )
    for op in sorted(set(re.findall(r"\bOP_[A-Z0-9]+(?:_[A-Z0-9]+)*\b", text))):
        tokens.add(op.lower())

    for part in fixture_id.removeprefix("scripts.").split("_"):
        if part in {
            "p2pkh",
            "p2sh",
            "p2wpkh",
            "p2wsh",
            "p2tr",
            "taproot",
            "tapscript",
            "multisig",
            "cltv",
            "csv",
            "sighash",
        }:
            tokens.add(part)
    return sorted(tokens)


def group_tags(meta: dict[str, Any], fixture_id: str, rules: list[str]) -> list[str]:
    tags = set(rules)
    template = str(meta.get("template", "")).lower()
    if template:
        tags.add(template)
    name = fixture_id.removeprefix("scripts.")
    for marker in ("hash", "numeric", "locktime", "multisig", "altstack", "stack", "taproot", "witness"):
        if marker in name:
            tags.add(marker)
    if any(rule in rules for rule in ("op_checklocktimeverify", "cltv")):
        tags.add("locktime")
    if any(rule in rules for rule in ("op_checksequenceverify", "csv")):
        tags.add("relative_locktime")
    return sorted(tags)


def copy_group(
    fixtures_dir: Path,
    output_dir: Path,
    meta_path: Path,
    *,
    write: bool,
) -> dict[str, Any]:
    meta = load_json(meta_path)
    fixture_id = fixture_id_for(meta_path)
    prefix = source_prefix(meta_path)
    group_dir = output_dir / fixture_id
    files = related_files(fixtures_dir, meta_path, meta)

    if write:
        if group_dir.exists():
            shutil.rmtree(group_dir)
        group_dir.mkdir(parents=True, exist_ok=True)

    copied: list[dict[str, Any]] = []
    categories: dict[str, list[str]] = {}
    for source in files:
        target_name = source.name
        target = group_dir / target_name
        if write:
            shutil.copy2(source, target)
        rel = f"{fixture_id}/{target_name}"
        category = classify(source, prefix, meta_path)
        categories.setdefault(category, []).append(rel)
        copied.append(
            {
                "path": rel,
                "source_path": str(source.relative_to(repo_root())),
                "category": category,
                "size_bytes": source.stat().st_size,
                "sha256": sha256_file(source),
            }
        )

    rules = required_rules(meta, fixture_id)
    missing = [field for field in REQUIRED_FIELDS if field not in meta]
    entry = {
        "fixture_id": fixture_id,
        "category": "script",
        "chain": "testnet4",
        "height": meta.get("height"),
        "block_hash": meta.get("block_hash", ""),
        "txid": meta.get("txid", ""),
        "input_index": meta.get("input_index"),
        "template": meta.get("template", ""),
        "spent_script_pubkey": meta.get("spent_script_pubkey", ""),
        "prev_amount_sats": meta.get("prev_amount_sats"),
        "tx_version": meta.get("tx_version"),
        "locktime": meta.get("locktime"),
        "input_sequence": meta.get("input_sequence"),
        "required_rules": rules,
        "groups": group_tags(meta, fixture_id, rules),
        "expected_result": "valid",
        "source_port": "Java",
        "source_meta": str(meta_path.relative_to(repo_root())),
        "source_prefix": prefix,
        "source_files": copied,
        "files": {key: sorted(value) for key, value in sorted(categories.items())},
        "portability_status": "raw_imported",
        "java_blocker": meta.get("java_blocker", ""),
        "missing_rule": meta.get("missing_rule", ""),
        "raw_meta": meta,
        "import_warnings": [f"missing required metadata field: {field}" for field in missing],
    }
    return entry


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--java-fixtures-dir",
        default=str(root / "Nodes/Java/src/test/resources/fixtures"),
    )
    parser.add_argument(
        "--output-dir",
        default=str(root / "Nodes/Shared/conformance/fixtures/scripts"),
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    fixtures_dir = Path(args.java_fixtures_dir).resolve()
    output_dir = Path(args.output_dir).resolve()
    meta_files = sorted(fixtures_dir.glob("*_meta.json"), key=lambda p: p.name)
    if not meta_files:
        raise SystemExit(f"no Java fixture metadata files found in {fixtures_dir}")

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)
        for old_group in output_dir.glob("scripts.*"):
            if old_group.is_dir():
                shutil.rmtree(old_group)

    entries = [copy_group(fixtures_dir, output_dir, meta, write=not args.dry_run) for meta in meta_files]
    entries.sort(key=lambda entry: (entry.get("height") or 0, entry["fixture_id"]))
    manifest = {
        "schema": "shared.script_fixtures.v1",
        "source": "Nodes/Java/src/test/resources/fixtures",
        "source_port": "Java",
        "portability_status": "raw_imported",
        "fixture_count": len(entries),
        "fixtures": entries,
    }

    if not args.dry_run:
        manifest_path = output_dir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"fixture_count": len(entries), "output_dir": str(output_dir)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
