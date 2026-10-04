"""Build, verify and consume the retained canonical Shared fixture package."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import uuid

from state_root import ROOT, PATHS, journal, mkdir

ROOTS = ("conformance/fixtures", "testing/fixtures")
FORMAT = "rb.canonical_tar.v1"
REJECT_FIXTURES = (
    "scripts.p2pkh_sighash_single_38010", "scripts.bare_multisig_27840",
    "scripts.p2sh_add_51340", "scripts.p2wsh_op1_only_31842",
    "scripts.p2tr_scriptpath_44295", "scripts.p2tr_tapscript_numequal_32712",
)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fixture_files(shared: Path) -> list[Path]:
    files = []
    for name in ROOTS:
        source = shared / name
        if not source.is_dir() or source.is_symlink():
            raise ValueError(f"missing fixture root: {name}")
        for path in source.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError(f"unsupported fixture entry: {path}")
            if path.is_file():
                files.append(path)
    return sorted(files, key=lambda p: p.relative_to(shared).as_posix())


def write_tar(base: Path, files: list[Path], output) -> None:
    with tarfile.open(fileobj=output, mode="w|", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(files, key=lambda p: p.relative_to(base).as_posix()):
            if not path.is_file() or path.is_symlink():
                raise ValueError(f"unsupported tar entry: {path}")
            info = tarfile.TarInfo(path.relative_to(base).as_posix())
            info.size = path.stat().st_size
            info.mode = 0o644
            info.mtime = info.uid = info.gid = 0
            info.uname = info.gname = ""
            with path.open("rb") as stream:
                archive.addfile(info, stream)


def reject_inputs(shared: Path) -> list[str]:
    manifest = json.loads((shared / "conformance/fixtures/scripts/manifest.json").read_text())
    fixtures = {f["fixture_id"]: f for f in manifest["fixtures"]}
    return sorted({"conformance/fixtures/scripts/manifest.json", *(
        "conformance/fixtures/scripts/" + p
        for name in REJECT_FIXTURES for paths in fixtures[name]["files"].values() for p in paths)})


def package_path(digest: str, store: Path | None = None) -> Path:
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("fixture_hash must be lowercase SHA-256")
    return (store or PATHS["packages"]) / f"rosetta-fixtures-{digest}.tar"


def verify(digest: str, store: Path | None = None) -> Path:
    path = package_path(digest, store)
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"retained fixture package missing: {digest}")
    actual = sha256(path)
    if actual != digest:
        raise ValueError(f"fixture package mismatch: expected={digest} actual={actual}")
    return path


def publish(path: Path, data: bytes) -> None:
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError(f"immutable receipt differs: {path.name}")
        return
    temp = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    journal("receipt", temp, {"remove_temporary": str(temp)})
    try:
        with temp.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temp, path)
        except FileExistsError:
            if path.read_bytes() != data:
                raise ValueError(f"immutable receipt differs: {path.name}")
    finally:
        temp.unlink(missing_ok=True)


def build(shared: Path = ROOT / "Nodes/Shared", store: Path | None = None) -> dict:
    store = store or PATHS["packages"]
    mkdir(store)
    files = fixture_files(shared)
    entries = [{"path": p.relative_to(shared).as_posix(), "size": p.stat().st_size, "sha256": sha256(p)} for p in files]
    temp = store / (".package-" + uuid.uuid4().hex)
    journal("package", temp, {"remove_temporary": str(temp)})
    try:
        with temp.open("xb") as stream:
            write_tar(shared, files, stream)
            stream.flush()
            os.fsync(stream.fileno())
        digest = sha256(temp)
        # Refuse a source mutation while packaging instead of issuing a false receipt.
        with tarfile.open(temp) as archive:
            observed = [{"path": m.name, "size": m.size, "sha256": hashlib.sha256(archive.extractfile(m).read()).hexdigest()} for m in archive]
        if observed != entries:
            raise ValueError("fixture tree changed during package build")
        dest = package_path(digest, store)
        journal("retain_package", dest, {"retain_evidence": str(dest)})
        try:
            os.link(temp, dest)
        except FileExistsError:
            verify(digest, store)
        receipt = {"schema": "rb.fixture_package.v1", "canonicalization": FORMAT,
                   "fixture_hash": digest, "roots": list(ROOTS), "files": entries,
                   "must_reject_inputs": reject_inputs(shared)}
        publish(dest.with_suffix(".json"), (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode())
        return receipt
    finally:
        temp.unlink(missing_ok=True)


def unpack(digest: str, destination: Path, store: Path | None = None) -> None:
    archive_path = verify(digest, store)
    mkdir(destination)
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        seen = set()
        for member in members:
            name = PurePosixPath(member.name)
            if (not member.isfile() or name.is_absolute() or ".." in name.parts
                    or member.name in seen or not any(member.name.startswith(r + "/") for r in ROOTS)):
                raise ValueError(f"unsafe fixture member: {member.name}")
            seen.add(member.name)
            target = destination.joinpath(*name.parts)
            if not target.resolve().is_relative_to(destination.resolve()) or target.is_symlink():
                raise ValueError(f"unsafe fixture destination: {member.name}")
        for member in members:
            target = destination / member.name
            mkdir(target.parent)
            journal("extract", target, {"remove_generated": str(target)})
            with archive.extractfile(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o644)


def java_resources(root: Path, shared: Path) -> None:
    mapping = json.loads((root / "Nodes/Java/fixture_resources.json").read_text())
    destination = root / "Nodes/Java/target/generated-test-resources/fixtures"
    for row in mapping["files"]:
        source = (shared / row["shared_path"] if row["disposition"] == "package"
                  else root / "Nodes/Java/src/test/resources/fixtures" / row["resource"])
        if sha256(source) != row["sha256"]:
            raise ValueError(f"Java fixture mismatch: {row['resource']}")
        target = destination / row["resource"]
        mkdir(target.parent)
        shutil.copyfile(source, target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shared", type=Path, default=ROOT / "Nodes/Shared")
    parser.add_argument("--store", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--unpack", type=Path)
    parser.add_argument("--verify")
    parser.add_argument("--java-resources", action="store_true")
    args = parser.parse_args()
    if args.verify:
        print(verify(args.verify, args.store))
        return
    receipt = build(args.shared, args.store)
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    destination = args.unpack or ROOT / "Nodes/Java/target/fixture-package"
    if args.unpack or args.java_resources:
        unpack(receipt["fixture_hash"], destination, args.store)
    if args.java_resources:
        java_resources(ROOT, destination)
    print(json.dumps({"fixture_hash": receipt["fixture_hash"]}))


if __name__ == "__main__":
    main()
