#!/usr/bin/env python3
"""Sequential pybitnode-sync batches with fcntl exclusive lock (.sync_batch_loop.lock); read-only validated_height polls."""

from __future__ import annotations

import argparse
import datetime as _dt
import fcntl
import importlib.util
import os
import subprocess
import sys
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _utc_ts() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_sync_progress(repo_root: Path):
    path = repo_root / "scripts" / "sync_progress_report.py"
    spec = importlib.util.spec_from_file_location("sync_progress_report", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def _validated_height(spr_mod, *, datadir: Path, chain: str) -> int:
    db = (datadir / "pybitnode.db").resolve()
    return spr_mod.read_validated_height_db(db, chain=chain)


def _acquire_exclusive_nonblocking(lock_path: Path) -> object:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fp = lock_path.open("a+b")
    fcntl.flock(fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    return fp


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run pybitnode-sync in sequential batches "
        "(fcntl lock .sync_batch_loop.lock; polls validated_height via read-only SQLite)."
    )
    parser.add_argument("--datadir", type=Path, required=True, help="datadir path (expects pybitnode.db inside)")
    parser.add_argument("--target", type=int, required=True, help="passed as --blocks-target")
    parser.add_argument("--blocks-max", type=int, default=200, dest="blocks_max")
    parser.add_argument(
        "--log",
        type=Path,
        default=None,
        help="append tee target (default: <repo>/sync_batch_run.log)",
    )
    parser.add_argument("--max-batches", type=int, default=1000)
    parser.add_argument("--chain", default="testnet4", help="chain_state.chain for RO height queries")
    parser.add_argument("--sync", type=Path, default=None, help="pybitnode-sync executable (default: .venv)")
    parser.add_argument(
        "--peers",
        default="",
        help="optional comma-separated list passed through as --peers when non-empty",
    )
    parser.add_argument(
        "--no-header-refresh",
        action="store_true",
        help="pass --no-header-refresh to pybitnode-sync",
    )
    parser.add_argument(
        "sync_extra",
        nargs=argparse.REMAINDER,
        help="extras forwarded to pybitnode-sync; start with `--` "
        "(example: `./scripts/sync_batch_loop.sh … -- --connect-only`)",
    )
    ns = parser.parse_args(argv)

    repo_root = _repo_root()
    spr_mod = _load_sync_progress(repo_root)
    sync_bin = ns.sync if ns.sync is not None else repo_root / ".venv" / "bin" / "pybitnode-sync"
    datadir = ns.datadir.expanduser().resolve()
    lock_path = datadir / ".sync_batch_loop.lock"
    log_path = (ns.log if ns.log is not None else repo_root / "sync_batch_run.log").expanduser()

    if not sync_bin.exists():
        print(f"error: pybitnode-sync missing: {sync_bin}", file=sys.stderr)
        return 1
    extra = ns.sync_extra
    if extra and extra[0] == "--":
        extra = extra[1:]

    try:
        lock_fp = _acquire_exclusive_nonblocking(lock_path)
    except BlockingIOError:
        print(f"error: lock busy (another sync_batch_loop?): {lock_path}", file=sys.stderr)
        return 2
    try:
        sync_env = {
            **os.environ,
            "MAX_OUTBOUND_PEERS": os.environ.get("MAX_OUTBOUND_PEERS", "1"),
            "PARALLEL_BLOCK_DOWNLOADS": os.environ.get("PARALLEL_BLOCK_DOWNLOADS", "0"),
            "SKIP_GETADDR": os.environ.get("SKIP_GETADDR", "1"),
        }
        for batch_num in range(1, ns.max_batches + 1):
            before = _validated_height(spr_mod, datadir=datadir, chain=ns.chain)
            if before >= ns.target:
                print(f"done: validated_height={before} (>= target {ns.target})")
                return 0

            ts_start = _utc_ts()
            start_line = f"=== batch {batch_num} start_validated={before} {ts_start} ==="
            print()
            print(start_line)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8", errors="replace") as lf:
                lf.write("\n")
                lf.write(start_line + "\n")

            cmd: list[str] = [
                os.fspath(sync_bin),
                "--datadir",
                os.fspath(datadir),
                "--blocks-target",
                str(ns.target),
                "--blocks-max",
                str(ns.blocks_max),
            ]
            if ns.no_header_refresh:
                cmd.append("--no-header-refresh")
            if ns.peers.strip():
                cmd.extend(["--peers", ns.peers.strip()])
            cmd.extend(extra)

            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=sync_env,
                cwd=os.fspath(repo_root),
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            with log_path.open("a", encoding="utf-8", errors="replace") as lf:
                for chunk in proc.stdout:
                    sys.stdout.write(chunk)
                    lf.write(chunk)
            exit_code = int(proc.wait())
            after = _validated_height(spr_mod, datadir=datadir, chain=ns.chain)
            vd = after - before
            ts_end = _utc_ts()
            end_line = (
                f"=== batch {batch_num} end_validated={after} downloaded_delta={vd} "
                f"exit={exit_code} ({ts_end}) validated_delta={vd} ==="
            )
            print(end_line)
            with log_path.open("a", encoding="utf-8", errors="replace") as lf:
                lf.write(end_line + "\n")

            if vd == 0 and exit_code == 0:
                stall_line = f"=== STALL validated_delta=0 exit=0 batch={batch_num} ({ts_end}) ==="
                print(stall_line)
                with log_path.open("a", encoding="utf-8", errors="replace") as lf:
                    lf.write(stall_line + "\n")
                print(
                    f"stall: validated_height unchanged ({after}); sync exit 0 (consensus stall?)",
                    file=sys.stderr,
                )
                return 5

        after = _validated_height(spr_mod, datadir=datadir, chain=ns.chain)
        print(
            f"error: max batches reached ({ns.max_batches}); validated_height={after} target={ns.target}",
            file=sys.stderr,
        )
        return 4
    finally:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)
        lock_fp.close()


if __name__ == "__main__":
    raise SystemExit(main())
