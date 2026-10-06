#!/usr/bin/env python3
"""Fail a gate unless the binary just built matches the target's identity."""

import hashlib
import json
import pathlib
import sys


def digest_of(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def check(info, crypto, store, commit, binary):
    digest = digest_of(binary)
    bad = []
    for key, want in (
        ("crypto_backend", crypto),
        ("store_mode", store),
        ("source_commit", commit),
    ):
        if info.get(key) != want:
            bad.append(f"{key}: have {info.get(key)!r} want {want!r}")
    if info.get("binary_sha256") != digest:
        bad.append(f"binary_sha256: have {info.get('binary_sha256')!r} want {digest!r}")
    if bad:
        sys.exit("build-info mismatch: " + "; ".join(bad))


def stamp(result_path, info_path, binary):
    info = json.loads(pathlib.Path(info_path).read_text())
    digest = digest_of(binary)
    if info.get("binary_sha256") != digest:
        sys.exit(
            "refusing provenance stamp: binary_sha256 "
            f"{info.get('binary_sha256')!r} is not the binary just built ({digest})"
        )
    result = json.loads(pathlib.Path(result_path).read_text())
    provenance = dict(result.get("provenance") or {})
    provenance["binary_sha256"] = info["binary_sha256"]
    provenance["source_commit"] = info["source_commit"]
    result["provenance"] = provenance
    text = json.dumps(result, separators=(",", ":")) + "\n"
    pathlib.Path(result_path).write_text(text)


def main():
    mode = sys.argv[1]
    if mode == "check":
        info = json.loads(sys.argv[2])
        check(info, sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    elif mode == "stamp":
        stamp(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    main()
