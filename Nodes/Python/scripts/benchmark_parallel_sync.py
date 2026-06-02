#!/usr/bin/env python3
"""Compare wall-clock block sync with PARALLEL_BLOCK_DOWNLOADS=0 vs >0.

Always uses an isolated datadir under the system temp directory (or --work-root).
By default **never** reads or writes the repository ``./data`` directory; pass
``--seed-dir`` only when you intend to clone a template datadir you control.

Example (live network, small batch on testnet4)::

    .venv/bin/python scripts/benchmark_parallel_sync.py compare \\
        --chain testnet4 --blocks-max 16 --blocks-target 500000 \\
        --log-level warning

With ``--no-header-refresh`` and no ``--seed-dir``, the benchmark first clones a minimal
datadir by running one subprocess with networked header refresh and ``blocks_max=1``, then
times two runs from copies of that seed (still never touches repo ``./data``).

Example (stable peer, skip header chatter during timed runs)::

    .venv/bin/python scripts/benchmark_parallel_sync.py compare \\
        --chain testnet4 --blocks-max 16 --blocks-target 17 \\
        --peers HOST:48333 --no-header-refresh --log-level warning

Code-only validation (no peers): see ``tests/test_block_sync.py`` (parallel
batch + ``request_block_from_peers_parallel``).
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _reject_repo_default_data(path: Path) -> None:
    """Refuse to use the repo's production ``data/`` as a write target."""
    canonical_data = (_repo_root() / "data").resolve()
    if path.resolve() == canonical_data:
        raise SystemExit(
            "Refusing to use the repository ./data directory. "
            "Pick a temp path or another explicit --work-root / copy target."
        )


def _ensure_owner_writable_tree(root: Path) -> None:
    """Allow sync lock + SQLite writes after ``copytree`` from read-only seeds (e.g. ``chmod -R a-w``).

    Copies preserve source permission bits; benchmarks must still mutate the isolated run dirs only.
    """
    try:
        m = root.stat().st_mode
        root.chmod(m | stat.S_IWUSR)
    except OSError:
        pass
    for path in root.rglob("*"):
        try:
            m = path.lstat().st_mode
            if stat.S_ISLNK(m):
                continue
            path.chmod(m | stat.S_IWUSR)
        except OSError:
            pass


def _copy_datadir_template(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dest, symlinks=True, dirs_exist_ok=True)
    _ensure_owner_writable_tree(dest)


def _run_sync_subprocess(
    *,
    datadir: Path,
    chain: str,
    blocks_max: int,
    blocks_target: int,
    parallel: int,
    peers: str,
    log_level: str,
    timeout: float | None,
    no_header_refresh: bool,
) -> tuple[int, float]:
    env = os.environ.copy()
    env["PARALLEL_BLOCK_DOWNLOADS"] = str(parallel)
    env["CHAIN"] = chain
    env["BLOCKS_MAX_PER_RUN"] = str(blocks_max)
    env["BLOCKS_TARGET_HEIGHT"] = str(blocks_target)
    if peers:
        env["PEERS"] = peers

    cmd = [
        sys.executable,
        "-m",
        "pybitnode.sync_runner",
        "--datadir",
        str(datadir),
        "--chain",
        chain,
        "--blocks-max",
        str(blocks_max),
        "--blocks-target",
        str(blocks_target),
        "--log-level",
        log_level,
    ]
    if peers:
        cmd.extend(["--peers", peers])
    if no_header_refresh:
        cmd.append("--no-header-refresh")

    t0 = time.perf_counter()
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-8000:] if proc.stderr else "(no stderr)\n")
        sys.stderr.write(proc.stdout[-4000:] if proc.stdout else "")
    return proc.returncode, elapsed


def _materialize_headers_seed(
    *,
    dest: Path,
    chain: str,
    blocks_target: int,
    peers: str,
    log_level: str,
    timeout: float | None,
) -> tuple[int, float]:
    """One lightweight sync WITH header networking to populate SQLite headers.

    Uses ``blocks_max=1`` so prep stays small while ``sync_headers`` still runs.
    Subsequent compare runs should use ``--no-header-refresh`` and the same
    ``blocks_target`` so local headers cover the timed block range.
    """
    dest.mkdir(parents=True, exist_ok=True)
    print(
        "\n(Materializing isolated seed: networked header refresh + blocks_max=1; "
        f"datadir={dest})",
    )
    return _run_sync_subprocess(
        datadir=dest,
        chain=chain,
        blocks_max=1,
        blocks_target=blocks_target,
        parallel=0,
        peers=peers,
        log_level=log_level,
        timeout=timeout,
        no_header_refresh=False,
    )


def _cmd_compare(args: argparse.Namespace) -> int:
    work = Path(args.work_root) if args.work_root else Path(tempfile.gettempdir())
    work.mkdir(parents=True, exist_ok=True)
    _reject_repo_default_data(work)
    base = Path(tempfile.mkdtemp(prefix="pybitnode_parallel_bench_", dir=str(work)))

    seed: Path | None = Path(args.seed_dir).resolve() if args.seed_dir else None
    if seed is not None and not seed.is_dir():
        raise SystemExit(f"--seed-dir is not a directory: {seed}")
    canonical_data = (_repo_root() / "data").resolve()
    if seed is not None and seed == canonical_data:
        raise SystemExit(
            "Refusing --seed-dir ./data (copy headers+db to an isolated path first)."
        )

    dir_seq = base / "run_sequential"
    dir_par = base / "run_parallel"

    try:
        if seed:
            _copy_datadir_template(seed, dir_seq)
            _copy_datadir_template(seed, dir_par)
        elif args.no_header_refresh:
            if not args.peers:
                raise SystemExit(
                    "With --no-header-refresh but no --seed-dir you must pass --peers … "
                    "so the benchmark can clone a minimal temp seed (networked headers once, "
                    "blocks_max=1) before timing."
                )
            dir_mat = base / "_materialized_seed"
            code_m, elapsed_m = _materialize_headers_seed(
                dest=dir_mat,
                chain=args.chain,
                blocks_target=args.blocks_target,
                peers=args.peers,
                log_level=args.log_level,
                timeout=args.timeout,
            )
            print(f"materialize_seed exit={code_m} elapsed_s={elapsed_m:.3f}")
            if code_m != 0:
                return 1
            _copy_datadir_template(dir_mat, dir_seq)
            _copy_datadir_template(dir_mat, dir_par)
        else:
            dir_seq.mkdir()
            dir_par.mkdir()

        print(f"Work directory: {base}")
        print(
            f"Settings: chain={args.chain} blocks_max={args.blocks_max} "
            f"blocks_target={args.blocks_target} timeout={args.timeout}"
        )
        if args.peers:
            print(f"PEERS: {args.peers}")
        else:
            print("PEERS: (default discovery / DNS seeds)")

        print("\n--- PARALLEL_BLOCK_DOWNLOADS=0 ---")
        code0, t0 = _run_sync_subprocess(
            datadir=dir_seq,
            chain=args.chain,
            blocks_max=args.blocks_max,
            blocks_target=args.blocks_target,
            parallel=0,
            peers=args.peers,
            log_level=args.log_level,
            timeout=args.timeout,
            no_header_refresh=args.no_header_refresh,
        )
        print(f"exit={code0} elapsed_s={t0:.3f}")

        print("\n--- PARALLEL_BLOCK_DOWNLOADS=8 ---")
        code8, t8 = _run_sync_subprocess(
            datadir=dir_par,
            chain=args.chain,
            blocks_max=args.blocks_max,
            blocks_target=args.blocks_target,
            parallel=8,
            peers=args.peers,
            log_level=args.log_level,
            timeout=args.timeout,
            no_header_refresh=args.no_header_refresh,
        )
        print(f"exit={code8} elapsed_s={t8:.3f}")

        if code0 == 0 and code8 == 0 and t0 > 0:
            ratio = t8 / t0
            print(f"\nparallel_wallclock / sequential_wallclock = {ratio:.3f}")
        elif code0 != 0 or code8 != 0:
            print(
                "\nOne or both runs failed (non-zero exit). "
                "Fix connectivity or lower --blocks-target; see stderr above."
            )
            return 1

        return 0
    finally:
        if not args.keep:
            shutil.rmtree(base, ignore_errors=True)
        else:
            print(f"\nKept work directory: {base}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Benchmark PARALLEL_BLOCK_DOWNLOADS in an isolated temp datadir.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_cmp = sub.add_parser("compare", help="Run sequential (0) vs parallel (8) on two isolated dirs")
    p_cmp.add_argument("--chain", default="testnet4")
    p_cmp.add_argument("--blocks-max", type=int, default=16)
    p_cmp.add_argument("--blocks-target", type=int, default=2_000_000)
    p_cmp.add_argument("--peers", default="", help="Optional host:port,host2:port for PEERS")
    p_cmp.add_argument(
        "--seed-dir",
        default="",
        help="Optional template datadir copied into each run (same starting state).",
    )
    p_cmp.add_argument(
        "--work-root",
        default="",
        help="Directory under which temp benchmark dirs are created (default: system temp).",
    )
    p_cmp.add_argument("--log-level", default="warning")
    p_cmp.add_argument(
        "--timeout",
        type=float,
        default=900.0,
        help="Per-run subprocess timeout in seconds (default 900).",
    )
    p_cmp.add_argument(
        "--keep",
        action="store_true",
        help="Do not delete the temp work directory after the run.",
    )
    p_cmp.add_argument(
        "--no-header-refresh",
        action="store_true",
        help="Pass through to sync_runner (skip networked header refresh during timed runs).",
    )
    p_cmp.set_defaults(func=_cmd_compare)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
