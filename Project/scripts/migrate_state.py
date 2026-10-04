"""Copy and verify idle non-Core state; retain originals and recover interrupted cutovers."""
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
import subprocess

from build_fixture_package import sha256
from state_root import PATHS, journal, mkdir, primary_root

SOURCES = {"campaigns": "Project/.campaigns", "substrate": "Nodes/RosettaNode/substrate/.local"}
FREE_FLOOR = 5 * 1024**3


def inventory(root: Path) -> dict:
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            if stat.S_ISSOCK(info.st_mode):
                continue
            row = {"mode": stat.S_IMODE(info.st_mode), "mtime_ns": info.st_mtime_ns}
            if path.is_symlink():
                row.update(kind="symlink", target=os.readlink(path))
            elif path.is_file():
                row.update(kind="file", size=info.st_size, sha256=sha256(path))
            elif path.is_dir():
                row.update(kind="directory")
            else:
                raise ValueError(f"unsupported state entry: {path}")
            result[path.relative_to(root).as_posix()] = row
    return result


def assert_idle(root: Path) -> None:
    # Report PIDs only; process command lines may contain credentials.
    result = subprocess.run(["lsof", "-n", "-P", "-F", "pfa", "+D", str(root)], capture_output=True, text=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError("cannot establish state idleness with lsof")
    writers = set()
    pid = "unknown"
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("a") and line != "ar":
            writers.add(pid)
    pids = sorted(writers)
    if pids:
        raise RuntimeError("state is in use by PID(s): " + ", ".join(pids))


def save(path: Path, value: dict) -> None:
    mkdir(path.parent)
    temp = path.with_suffix(".pending")
    journal("migration_receipt", temp, {"remove_temporary": str(temp)})
    with temp.open("w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def freeze_campaign(source: Path) -> None:
    frozen = source / "campaign-v2"
    if not frozen.exists():
        return
    note = frozen / "FROZEN.txt"
    if not note.exists():
        journal("freeze_note", note, {"retain_evidence": str(note)})
        note.write_text(f"Frozen read-only on {datetime.date.today().isoformat()}. Historical campaign; new runs require a new campaign root.\n")
    for root, dirs, files in os.walk(frozen):
        for name in files + dirs:
            path = Path(root) / name
            if not path.is_symlink():
                mode = path.stat().st_mode & 0o777
                if mode & 0o222:
                    journal("freeze_mode", path, {"restore_mode": mode})
                    path.chmod(mode & ~0o222)
    frozen.chmod(frozen.stat().st_mode & ~0o222)


def migrate(repo: Path, key: str, apply: bool, idle=assert_idle, floor: int = FREE_FLOOR) -> dict:
    source, dest = repo / SOURCES[key], PATHS[key]
    marker = PATHS["root"] / "migrations" / (key + ".json")
    if marker.exists():
        existing = json.loads(marker.read_text())
        if existing.get("phase") == "complete":
            if not dest.is_dir() or not source.is_symlink() or source.resolve() != dest:
                raise ValueError("completed migration paths no longer match receipt")
            return existing
        raise ValueError(f"unfinished {key} migration; use --recover or --rollback")
    if not source.is_dir() or source.is_symlink():
        return {"class": key, "phase": "absent"}
    if dest.exists():
        raise ValueError(f"occupied destination for {key}")
    entries = inventory(source)
    size = sum(row.get("size", 0) for row in entries.values())
    parent = PATHS["root"] if PATHS["root"].exists() else PATHS["root"].parent
    free = shutil.disk_usage(parent).free
    if free - size < floor:
        raise ValueError(f"insufficient space for {key}: free={free} copy={size} floor={floor}")
    result = {"class": key, "source": str(source), "destination": str(dest), "phase": "planned",
              "bytes": size, "free_before": free, "file_count": len(entries),
              "date": datetime.date.today().isoformat()}
    result["retained_socket_paths"] = sorted(str(p.relative_to(source)) for p in source.rglob("*") if stat.S_ISSOCK(p.lstat().st_mode))
    if not apply:
        return result
    idle(source)
    backup = PATHS["root"] / "retained-originals" / key
    staging = dest.with_name(dest.name + ".copying")
    if backup.exists() or staging.exists():
        raise ValueError("occupied migration recovery path")
    result.update(backup=str(backup), staging=str(staging), inverse={"restore": str(backup), "to": str(source)})
    save(marker, result)
    if key == "substrate":
        freeze_campaign(source)
    entries = inventory(source)
    result["inventory_sha256"] = hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
    inventory_path = marker.with_name(key + "-inventory.json")
    save(inventory_path, entries)
    mkdir(dest.parent)
    journal("copy_state", staging, {"remove_copy_only_while_source_exists": str(source)})
    def ignore_sockets(directory, names):
        return [name for name in names if stat.S_ISSOCK((Path(directory) / name).lstat().st_mode)]
    shutil.copytree(source, staging, symlinks=True, copy_function=shutil.copy2, ignore=ignore_sockets)
    if inventory(staging) != entries or inventory(source) != entries:
        raise ValueError("state changed or copied contents/metadata differ; original retained")
    idle(source)
    result["phase"] = "verified"
    save(marker, result)
    mkdir(backup.parent)
    journal("retain_original", source, {"rename": str(backup), "to": str(source)})
    os.rename(source, backup)
    result["phase"] = "source_retained"
    save(marker, result)
    os.rename(staging, dest)
    result["phase"] = "switched"
    save(marker, result)
    # Compatibility for already-open checkouts; no bulk remains beneath the repo.
    source.symlink_to(dest, target_is_directory=True)
    result["phase"] = "complete"
    result["free_after"] = shutil.disk_usage(dest).free
    save(marker, result)
    return result


def recover(key: str, rollback: bool = False) -> dict:
    marker = PATHS["root"] / "migrations" / (key + ".json")
    result = json.loads(marker.read_text())
    source, dest, backup, staging = (Path(result[n]) for n in ("source", "destination", "backup", "staging"))
    if rollback:
        if backup.exists():
            if dest.exists():
                assert_idle(dest)
            if source.is_symlink() and source.resolve() == dest:
                source.unlink()
            elif source.exists():
                raise ValueError("rollback would replace an occupied source")
            os.rename(backup, source)
        elif not source.exists():
            raise ValueError("no original source available for rollback")
        result["phase"] = "rolled_back"
        save(marker, result)
        return result
    if result["phase"] == "complete":
        return result
    if not backup.exists() or source.exists() and not source.is_symlink():
        raise ValueError("source not switched; rollback and inspect the retained copy")
    expected = json.loads(marker.with_name(key + "-inventory.json").read_text())
    candidate = dest if dest.exists() else staging
    if inventory(candidate) != expected:
        raise ValueError("recovery copy differs from verified inventory")
    if candidate == staging:
        os.rename(staging, dest)
    if not source.is_symlink():
        source.symlink_to(dest, target_is_directory=True)
    result["phase"] = "complete"
    save(marker, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=primary_root())
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--class", dest="classes", action="append", choices=SOURCES)
    parser.add_argument("--recover", choices=SOURCES)
    parser.add_argument("--rollback", choices=SOURCES)
    args = parser.parse_args()
    if not (args.apply or args.recover or args.rollback):
        print(json.dumps([migrate(args.repo, key, False) for key in args.classes or SOURCES], indent=2))
        return
    mkdir(PATHS["root"])
    lock_path = PATHS["root"] / "migration.lock"
    journal("migration_lock", lock_path, {"remove_if_unlocked": str(lock_path)})
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.recover or args.rollback:
            result = recover(args.recover or args.rollback, bool(args.rollback))
            print(json.dumps(result, indent=2))
        else:
            for key in args.classes or SOURCES:
                print(json.dumps(migrate(args.repo, key, True), indent=2), flush=True)


if __name__ == "__main__":
    main()
