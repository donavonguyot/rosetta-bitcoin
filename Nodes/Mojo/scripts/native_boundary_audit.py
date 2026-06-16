#!/usr/bin/env python3
"""Audit the Mojo native shim boundary."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


DISALLOWED_DIRECT_LIB_RE = re.compile(
    r"(?:^|[/\s-])(lib)?(?:ssl|crypto|openssl|boringssl|libressl|sodium|mbedtls|wolfssl)(?:[.\s-]|$)",
    re.IGNORECASE,
)
SYSTEM_LIB_RE = re.compile(
    r"(?:^|/)(?:libSystem|libc\+\+|libstdc\+\+|libc|libm|libgcc_s|ld-linux|ld64|dyld|linux-vdso)",
    re.IGNORECASE,
)
APPROVED_DIRECT_LIB_RE = re.compile(r"(?:rocksdb|secp256k1)", re.IGNORECASE)
CONSENSUS_SHAPED_RE = re.compile(
    r"(?:sighash|script|tx|transaction|block|header|merkle|tapleaf|tapbranch|hash160|hash256|sha256|ripemd|utxo|proof)",
    re.IGNORECASE,
)
PACKAGE_CRYPTO_RE = re.compile(
    r"(?:openssl|libssl|libcrypto|boringssl|libressl|libsodium|mbedtls|wolfssl)",
    re.IGNORECASE,
)

APPROVED_EXACT_SYMBOLS = {
    "mojobitnode_crypto_metrics_reset": "secp256k1_crypto_telemetry",
    "mojobitnode_crypto_metric_len": "secp256k1_crypto_telemetry",
    "mojobitnode_native_crypto_available": "secp256k1_crypto",
    "mojobitnode_verify_ecdsa_der_bytes_len": "secp256k1_crypto",
    "mojobitnode_verify_ecdsa_der_hex": "secp256k1_crypto",
    "mojobitnode_verify_ecdsa_der_hex_len": "secp256k1_crypto",
    "mojobitnode_verify_schnorr_bytes_len": "secp256k1_crypto",
    "mojobitnode_verify_schnorr_hex_len": "secp256k1_crypto",
    "mojobitnode_verify_taproot_tweak_precomputed_bytes_len": "secp256k1_crypto",
    "mojobitnode_now_ms": "runtime_syscall",
    "mojobitnode_socket_connect_len": "runtime_syscall",
    "mojobitnode_socket_close": "runtime_syscall",
    "mojobitnode_socket_send_all": "runtime_syscall",
    "mojobitnode_socket_recv_exact": "runtime_syscall",
    "mojobitnode_write_text": "runtime_syscall",
    "mojobitnode_write_text_len": "runtime_syscall",
}
APPROVED_PREFIXES = {
    "mojobitnode_rocksdb_": "rocksdb_storage",
}


def run(args: list[str]) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def command_exists(name: str) -> bool:
    return any((Path(path) / name).exists() for path in os.environ.get("PATH", "").split(os.pathsep))


def direct_dependencies(path: Path) -> list[str]:
    if sys.platform == "darwin" and command_exists("otool"):
        lines = run(["otool", "-L", str(path)]).splitlines()[1:]
        return [line.strip().split(" ", 1)[0] for line in lines if line.strip()]
    if command_exists("readelf"):
        deps: list[str] = []
        for line in run(["readelf", "-d", str(path)]).splitlines():
            if "(NEEDED)" not in line:
                continue
            match = re.search(r"\[(.*?)\]", line)
            if match:
                deps.append(match.group(1))
        return deps
    if command_exists("otool"):
        lines = run(["otool", "-L", str(path)]).splitlines()[1:]
        return [line.strip().split(" ", 1)[0] for line in lines if line.strip()]
    raise RuntimeError("missing readelf or otool for direct dependency inspection")


def exported_symbols(path: Path) -> list[str]:
    if not command_exists("nm"):
        raise RuntimeError("missing nm for exported symbol inspection")
    symbols: list[str] = []
    for line in run(["nm", "-g", str(path)]).splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        symbol = parts[-1]
        if symbol.startswith("_mojobitnode_"):
            symbol = symbol[1:]
        if symbol.startswith("mojobitnode_"):
            symbols.append(symbol)
    return sorted(set(symbols))


def classify_symbol(symbol: str) -> str | None:
    if symbol in APPROVED_EXACT_SYMBOLS:
        return APPROVED_EXACT_SYMBOLS[symbol]
    for prefix, group in APPROVED_PREFIXES.items():
        if symbol.startswith(prefix):
            return group
    return None


def package_closure(command: str | None) -> list[str]:
    if not command:
        return []
    try:
        output = subprocess.check_output(shlex.split(command), text=True, stderr=subprocess.STDOUT)
    except Exception as exc:
        return [f"package-list-command-failed: {exc}"]
    return sorted(line for line in output.splitlines() if PACKAGE_CRYPTO_RE.search(line))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shim", required=True, help="path to libmojobitnode_shim")
    parser.add_argument("--package-list-command", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    shim = Path(args.shim)
    errors: list[str] = []
    warnings: list[str] = []
    if not shim.exists():
        errors.append(f"missing shim: {shim}")
        payload = {"schema": "mojo.native_boundary_audit.v1", "status": "failed", "errors": errors}
        print(json.dumps(payload, indent=2, sort_keys=True) if args.json else "\n".join(errors))
        return 1

    deps = direct_dependencies(shim)
    disallowed_deps = [dep for dep in deps if DISALLOWED_DIRECT_LIB_RE.search(dep)]
    if disallowed_deps:
        errors.append("disallowed direct crypto dependencies: " + ", ".join(disallowed_deps))

    unexpected_deps = [
        dep
        for dep in deps
        if not APPROVED_DIRECT_LIB_RE.search(dep)
        and not SYSTEM_LIB_RE.search(dep)
        and not dep.endswith(str(shim))
        and Path(dep).name != shim.name
    ]
    if unexpected_deps:
        warnings.append("unexpected non-crypto direct dependencies: " + ", ".join(unexpected_deps))

    symbols = exported_symbols(shim)
    classified = {symbol: classify_symbol(symbol) for symbol in symbols}
    unclassified = [symbol for symbol, group in classified.items() if group is None]
    if unclassified:
        errors.append("unclassified exported mojobitnode symbols: " + ", ".join(unclassified))
    consensus_shaped = [
        symbol for symbol, group in classified.items() if group is None and CONSENSUS_SHAPED_RE.search(symbol)
    ]
    if consensus_shaped:
        errors.append("consensus-shaped exported C symbols: " + ", ".join(consensus_shaped))

    payload = {
        "schema": "mojo.native_boundary_audit.v1",
        "shim": str(shim),
        "status": "failed" if errors else "passed",
        "direct_dependencies": deps,
        "exported_symbols": [{"name": symbol, "group": classified[symbol]} for symbol in symbols],
        "installed_crypto_package_closure": package_closure(args.package_list_command),
        "notes": [
            "installed_crypto_package_closure is OS package closure only; direct dependency failures are separate",
            "approved C groups are secp256k1_crypto, rocksdb_storage, and runtime_syscall",
        ],
        "warnings": warnings,
        "errors": errors,
    }
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"mojo_native_boundary_audit status={payload['status']} shim={shim}")
        print("direct_dependencies=" + ",".join(deps))
        if payload["installed_crypto_package_closure"]:
            print("installed_crypto_package_closure=" + ",".join(payload["installed_crypto_package_closure"]))
        for warning in warnings:
            print(f"warning: {warning}")
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
