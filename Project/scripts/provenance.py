"""Project-owned build receipts and retained-package verification."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from build_fixture_package import build, publish, sha256, unpack, verify
from state_root import ROOT, PATHS, mkdir

PORT_DIRS = {p.lower(): p for p in ("Cpp", "CSharp", "Go", "Java", "Mojo", "Rust", "Swift", "Zig", "OCaml")}

PROJECTION_SQL = """CREATE VIEW IF NOT EXISTS artifact_provenance AS
SELECT artifact_id, path,
coalesce(json_extract(summary_json, '$.provenance_status'), 'absent') AS provenance_status,
json_extract(summary_json, '$.provenance.run_ref') AS run_ref,
json_extract(summary_json, '$.provenance.fixture_hash') AS fixture_hash,
json_extract(summary_json, '$.provenance.source_commit') AS source_commit,
json_extract(summary_json, '$.provenance.binary_sha256') AS binary_sha256,
json_extract(summary_json, '$.provenance.toolchain_sha256') AS toolchain_sha256,
NULL AS port
FROM artifacts WHERE json_type(summary_json, '$.provenance_by_port') IS NULL
UNION ALL
SELECT artifact_id, artifacts.path, json_extract(p.value, '$.provenance_status'),
json_extract(p.value, '$.provenance.run_ref'),
json_extract(p.value, '$.provenance.fixture_hash'),
json_extract(p.value, '$.provenance.source_commit'),
json_extract(p.value, '$.provenance.binary_sha256'),
json_extract(p.value, '$.provenance.toolchain_sha256'), p.key
FROM artifacts, json_each(summary_json, '$.provenance_by_port') AS p"""


def command(args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def source_commit() -> str:
    changed = command(["git", "status", "--porcelain", "--untracked-files=all", "--", "Project/scripts", "Nodes", "Libraries",
                       ":(exclude)Nodes/Shared/conformance/results", ":(exclude)Nodes/Shared/testing/results",
                       ":(exclude)Nodes/Shared/conformance/crypto_comparisons", ":(exclude)Nodes/Shared/conformance/current_evidence.json"])
    if changed:
        raise ValueError("provenance builds require committed source inputs")
    return command(["git", "rev-parse", "HEAD"])


def image_id(image: str) -> str:
    identity = command(["docker", "image", "inspect", image, "--format", "{{.Id}}"])
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", identity):
        raise ValueError("Docker returned a non-SHA-256 image identity")
    return identity


def receipt_path(identity: str, source: dict | None = None) -> Path:
    digest = identity.removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid artifact digest")
    directory = PATHS["root"] / "build-receipts" / digest
    return directory / (source["source_commit"] + "-" + source["fixture_hash"] + ".json") if source else directory


def begin_build() -> dict:
    commit = source_commit()
    receipt = build()
    return {"source_commit": commit, "fixture_hash": receipt["fixture_hash"]}


def finish_build(start: dict, subject: str | Path, kind: str = "image") -> dict:
    if source_commit() != start["source_commit"] or build()["fixture_hash"] != start["fixture_hash"]:
        raise ValueError("source or fixtures changed during build")
    digest = image_id(str(subject)).removeprefix("sha256:") if kind == "image" else sha256(Path(subject))
    receipt = {"schema": "rb.build_receipt.v1", **start, "binary_sha256": digest, "subject_type": kind}
    destination = receipt_path(digest, start)
    mkdir(destination.parent)
    publish(destination, (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode())
    return receipt


def toolchain_sha256(zig: Path) -> str:
    """SHA256 of the zig compiler binary a gate will run."""
    path = zig.expanduser()
    if not path.is_file():
        raise ValueError(f"zig binary missing: {path}")
    return sha256(path)


def from_receipt(receipt: dict, run_ref: str | None = None) -> dict:
    result = {key: receipt[key] for key in ("fixture_hash", "source_commit", "binary_sha256")}
    if run_ref is not None:
        result["run_ref"] = run_ref
    validate({"provenance": result})
    return result


def for_image(image: str, run_ref: str | None = None, expected: dict | None = None) -> dict:
    identity = image_id(image)
    candidates = [receipt_path(identity, expected)] if expected else sorted(receipt_path(identity).glob("*.json"))
    if len(candidates) != 1:
        raise ValueError(f"executed image {identity} needs an unambiguous build receipt")
    path = candidates[0]
    if not path.is_file():
        raise ValueError(f"build receipt missing for executed image {identity}; rebuild with Project provenance tooling")
    receipt = json.loads(path.read_text())
    if receipt.get("binary_sha256") != identity.removeprefix("sha256:") or receipt.get("subject_type") != "image":
        raise ValueError("build receipt does not match executed image")
    return from_receipt(receipt, run_ref)


def validate(payload: dict, store: Path | None = None) -> dict:
    if payload.get("schema") == "benchmark.parallel_experiment":
        rows = payload.get("ports", [])
        if not isinstance(rows, list):
            raise ValueError("parallel ports must be an array")
        by_port = {}
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("port"), str) or row["port"] in by_port:
                raise ValueError("parallel ports require unique port names")
            by_port[row["port"]] = validate({"provenance": row["provenance"]} if "provenance" in row else {}, store)
        # A supplied top-level object must also be valid; it cannot mask per-port pins.
        if "provenance" in payload:
            validate({"provenance": payload["provenance"]}, store)
        statuses = {row["provenance_status"] for row in by_port.values()}
        status = next(iter(statuses)) if len(statuses) == 1 else "mixed" if statuses else "absent"
        return {"provenance_status": status, "provenance_by_port": by_port}
    if "provenance" not in payload:
        return {"provenance_status": "absent"}
    value = payload["provenance"]
    if not isinstance(value, dict):
        raise ValueError("provenance must be an object")
    if "run_ref" in value and not isinstance(value["run_ref"], str):
        raise ValueError("provenance.run_ref must be a string")
    if "toolchain_sha256" in value and (
        not isinstance(value["toolchain_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["toolchain_sha256"])
    ):
        raise ValueError("invalid provenance.toolchain_sha256")
    build_fields = ("fixture_hash", "source_commit", "binary_sha256")
    if not any(field in value for field in build_fields):
        if "toolchain_sha256" not in value:
            raise ValueError("invalid provenance.fixture_hash")
        return {"provenance_status": "toolchain", "provenance": dict(value)}
    for field, length in (("fixture_hash", 64), ("source_commit", 40), ("binary_sha256", 64)):
        if not isinstance(value.get(field), str) or not re.fullmatch(f"[0-9a-f]{{{length}}}", value[field]):
            raise ValueError(f"invalid provenance.{field}")
    verify(value["fixture_hash"], store)
    return {"provenance_status": "verified", "provenance": dict(value)}


def report(connection) -> None:
    print("| artifact | status | run_ref | fixture_hash | source_commit | binary_sha256 |")
    print("| --- | --- | --- | --- | --- | --- |")
    for path, raw in connection.execute("SELECT path, summary_json FROM artifacts ORDER BY path"):
        summary = json.loads(raw)
        rows = summary.get("provenance_by_port")
        for port, metadata in (rows.items() if rows is not None else [(None, summary)]):
            pins = metadata.get("provenance", {})
            values = [f"{path} ({port})" if port else path, metadata.get("provenance_status", "absent"), *(pins.get(k, "") for k in ("run_ref", "fixture_hash", "source_commit", "binary_sha256"))]
            print("| " + " | ".join(str(v).replace("|", "\\|").replace("\n", "\\n").replace("\r", "\\r") for v in values) + " |")


def prepare_port(port: str, run_ref: str | None = None) -> tuple[dict, dict]:
    directory = ROOT / "Nodes" / PORT_DIRS[port]
    config = json.loads(subprocess.check_output([
        "docker", "compose", "--env-file", "../Shared/docker/reference_topology.env",
        "-f", "docker/docker-compose.yml", "config", "--format", "json"], cwd=directory, text=True))
    images = {s["image"] for s in config["services"].values() if "build" in s}
    if len(images) != 1:
        raise ValueError(f"{port}: expected one port runtime image, got {sorted(images)}")
    image = images.pop()
    start = begin_build()
    try:
        pins = for_image(image, run_ref, start)
        if any(pins[key] != start[key] for key in start):
            raise ValueError("build receipt is for another source or package")
    except (ValueError, subprocess.CalledProcessError):
        subprocess.run(["make", "docker-build"], cwd=directory, check=True)
        finish_build(start, image)
        pins = for_image(image, run_ref, start)
    extracted = directory / "build/fixture-package"
    unpack(pins["fixture_hash"], extracted)
    return pins, {"RB_PROVENANCE_IMAGE": "sha256:" + pins["binary_sha256"], "RB_FIXTURE_SHARED": str(extracted), "DOCKER_REBUILD": "0"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig-binary", type=Path, help="Print the SHA256 of this zig binary and exit")
    parser.add_argument("--image")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.zig_binary:
        print(toolchain_sha256(args.zig_binary))
        return
    if not args.image:
        parser.error("--image is required unless --zig-binary is set")
    if not args.command:
        parser.error("provide the build command after --")
    started = begin_build()
    subprocess.run(args.command[1:] if args.command[0] == "--" else args.command, cwd=ROOT, check=True)
    print(json.dumps(finish_build(started, args.image), sort_keys=True))


if __name__ == "__main__":
    main()
