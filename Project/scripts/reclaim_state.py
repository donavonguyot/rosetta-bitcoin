"""Audit the two retained non-Core originals; deletion requires --apply."""
from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat

from migrate_state import SOURCES, assert_idle, inventory, save
from state_root import PATHS, journal, primary_root


def digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def sockets(root: Path) -> list[str]:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if stat.S_ISSOCK(p.lstat().st_mode))


def audit(repo: Path, idle=assert_idle) -> dict:
    result = {"classes": {}, "blockers": []}
    for key, relative in SOURCES.items():
        marker = PATHS["root"] / "migrations" / f"{key}.json"
        migration = json.loads(marker.read_text())
        source, dest = repo / relative, PATHS[key]
        original = PATHS["root"] / "retained-originals" / key
        row = {"destination": f"state:{key}/", "original": f"retained-originals/{key}", "checks": {}}
        result["classes"][key] = row
        row["checks"]["complete_journal"] = migration.get("phase") == "complete" and not dest.with_name(dest.name + ".copying").exists()
        row["checks"]["compatibility_link"] = source.is_symlink() and source.resolve() == dest.resolve() and dest.resolve().is_relative_to(PATHS["root"].resolve())
        row["checks"]["original_path"] = original.is_dir() and not original.is_symlink() and original.resolve() == Path(migration["backup"]).resolve()
        if not all(row["checks"].values()):
            result["blockers"].append({"class": key, "reason": "migration paths or journal do not match", "checks": row["checks"]})
            continue
        for label, path in (("destination", dest), ("original", original)):
            try:
                idle(path)
                row["checks"][label + "_idle"] = True
            except RuntimeError as exc:
                row["checks"][label + "_idle"] = False
                result["blockers"].append({"class": key, "reason": str(exc), "location": label})
        expected = json.loads(marker.with_name(f"{key}-inventory.json").read_text())
        old, live = inventory(original), inventory(dest)
        row["original_inventory_sha256"] = digest(old)
        row["recorded_inventory_sha256"] = migration["inventory_sha256"]
        row["checks"]["original_unchanged"] = old == expected and digest(expected) == migration["inventory_sha256"]
        row["missing_destination_paths"] = sorted(set(old) - set(live))
        row["changed_destination_paths"] = [p for p in sorted(set(old) & set(live)) if old[p] != live[p]]
        row["destination_additions"] = sorted(set(live) - set(old))
        row["checks"]["portable_comparison"] = not row["missing_destination_paths"] and not row["changed_destination_paths"]
        row["original_only_sockets"] = sorted(set(sockets(original)) - set(sockets(dest)))
        row["checks"]["expected_sockets"] = row["original_only_sockets"] == migration.get("retained_socket_paths", [])
        row["logical_bytes"] = sum(v.get("size", 0) for v in old.values())
        if not row["checks"]["original_unchanged"] or not row["checks"]["portable_comparison"] or not row["checks"]["expected_sockets"]:
            result["blockers"].append({"class": key, "reason": "inventory comparison failed; see class path lists"})
        if key == "substrate":
            prefix = "campaign-v2/"
            expected_frozen = {p: v for p, v in expected.items() if p.startswith(prefix)}
            live_frozen = {p: v for p, v in live.items() if p.startswith(prefix)}
            frozen = dest / "campaign-v2"
            writable = [p for p, v in live_frozen.items() if v["kind"] != "symlink" and v["mode"] & 0o222]
            row["frozen_campaign"] = {"expected_inventory_sha256": digest(expected_frozen), "live_inventory_sha256": digest(live_frozen), "writable_paths": writable, "note_present": (frozen / "FROZEN.txt").is_file()}
            row["checks"]["frozen_campaign"] = bool(expected_frozen) and expected_frozen == live_frozen and not writable and not (frozen.stat().st_mode & 0o222) and (frozen / "FROZEN.txt").is_file()
            if not row["checks"]["frozen_campaign"]:
                result["blockers"].append({"class": key, "reason": "frozen campaign check failed"})
    pending = sorted(p.name for p in (PATHS["root"] / "migrations").glob("*.pending"))
    if pending:
        result["blockers"].append({"reason": "pending migration receipts", "paths": pending})
    return result


def reclaim(repo: Path, receipt_path: Path, apply=False, idle=assert_idle) -> dict:
    if receipt_path.exists():
        raise ValueError("reclaim receipts are append-only; choose a new receipt path")
    result = {"schema": "rb.state_reclaim.v1", "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "irreversibility": "Deletion of the two owner-authorized retained originals is irreversible.",
              "free_before": shutil.disk_usage(PATHS["root"]).free, "deleted": [], "logical_bytes_deleted": 0}
    result.update(audit(repo, idle))
    result["status"] = "blocked" if result["blockers"] else "verified"
    result["free_after"] = shutil.disk_usage(PATHS["root"]).free
    result["host_free_delta"] = result["free_after"] - result["free_before"]
    save(receipt_path, result)
    if result["blockers"] or not apply:
        return result
    # Recheck idleness immediately before either original is removed.
    for key in SOURCES:
        idle(PATHS[key])
        idle(PATHS["root"] / "retained-originals" / key)
    for key in SOURCES:
        original = PATHS["root"] / "retained-originals" / key
        if original.is_symlink() or original.resolve().parent != (PATHS["root"] / "retained-originals").resolve():
            raise ValueError("refusing a changed retained-original path")
        result["status"] = "deleting"
        result["next_class"] = key
        save(receipt_path, result)
        journal("reclaim_retained_original", original, {"inverse": None, "authorization_receipt": str(receipt_path)})
        # Frozen directories need owner write access for unlink; change originals only.
        for directory, dirs, files in os.walk(original, followlinks=False):
            path = Path(directory)
            path.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)
        shutil.rmtree(original)
        result["deleted"].append(key)
        result["logical_bytes_deleted"] += result["classes"][key]["logical_bytes"]
        result["free_after"] = shutil.disk_usage(PATHS["root"]).free
        result["host_free_delta"] = result["free_after"] - result["free_before"]
        save(receipt_path, result)
    result["status"] = "complete"
    result.pop("next_class", None)
    save(receipt_path, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if not args.receipt.resolve().is_relative_to((PATHS["root"] / "migrations").resolve()):
        parser.error("receipt must be under state-root migrations/")
    with (PATHS["root"] / "migration.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = reclaim(primary_root(), args.receipt, args.apply)
    print(json.dumps({"status": result["status"], "blockers": result["blockers"], "logical_bytes_deleted": result["logical_bytes_deleted"], "host_free_delta": result["host_free_delta"], "receipt": str(args.receipt)}, indent=2))
    return 1 if result["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
