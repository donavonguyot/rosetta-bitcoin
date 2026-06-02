#!/usr/bin/env python3
"""Repair blocks.file_offset/size by scanning blk*.dat and matching block_hash rows.

Parallel block downloads can leave SQLite metadata pointing at the wrong file
position (monotonic append order broken). Rebuild then fails with
``Block size mismatch``. This tool rescans from the first affected height and
updates offsets/sizes in place (read-only on blk files).
"""

from __future__ import annotations

import argparse
import struct
import sqlite3
import sys
from pathlib import Path

from pybitnode.chain.params import get_chain
from pybitnode.storage.blocks import block_hash_hex_from_payload


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _read_block_at(handle, offset: int, magic: bytes) -> tuple[int, bytes] | None:
    handle.seek(offset)
    if handle.read(4) != magic:
        return None
    (payload_size,) = struct.unpack("<I", handle.read(4))
    payload = handle.read(payload_size)
    if len(payload) != payload_size:
        return None
    return 8 + payload_size, payload


def repair(
    *,
    db_path: Path,
    blocks_dir: Path,
    chain: str,
    start_height: int,
    dry_run: bool,
) -> int:
    params = get_chain(chain)
    magic = params.magic
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT height, block_hash, file_name, file_offset, size FROM blocks "
            "WHERE height >= ? ORDER BY height",
            (start_height,),
        ).fetchall()
        if not rows:
            print(f"no blocks at or above height {start_height}")
            return 0

        prev = conn.execute(
            "SELECT file_name, file_offset, size FROM blocks WHERE height = ?",
            (start_height - 1,),
        ).fetchone()
        if prev is None and start_height > 1:
            print(f"error: missing parent block at height {start_height - 1}", file=sys.stderr)
            return 1
        if prev is None:
            cursor: dict[str, int] = {f.name: 0 for f in sorted(blocks_dir.glob("blk*.dat"))}
        else:
            cursor = {prev["file_name"]: int(prev["file_offset"]) + 8 + int(prev["size"])}

        fixed = 0
        handles: dict[str, object] = {}
        for row in rows:
            fn = row["file_name"]
            path = blocks_dir / fn
            if fn not in handles:
                handles[fn] = path.open("rb")
            handle = handles[fn]
            off = cursor.get(fn, 0)
            expected = row["block_hash"].lower()
            db_off, db_size = int(row["file_offset"]), int(row["size"])
            parsed = _read_block_at(handle, off, magic)
            if parsed is None:
                print(f"error: no valid block at {fn}:{off} for height {row['height']}", file=sys.stderr)
                return 1
            span, payload = parsed
            got = block_hash_hex_from_payload(payload)
            if got.lower() == expected:
                if db_off != off or db_size != len(payload):
                    print(
                        f"fix height={row['height']} {fn} "
                        f"offset {db_off}->{off} size {db_size}->{len(payload)}"
                    )
                    if not dry_run:
                        conn.execute(
                            "UPDATE blocks SET file_offset = ?, size = ? WHERE height = ?",
                            (off, len(payload), row["height"]),
                        )
                    fixed += 1
                cursor[fn] = off + span
                continue

            # Scan forward in this file for the expected hash.
            file_size = path.stat().st_size
            scan = off
            found: tuple[int, int] | None = None
            while scan < file_size:
                trial = _read_block_at(handle, scan, magic)
                if trial is None:
                    scan += 1
                    continue
                span_t, payload_t = trial
                if block_hash_hex_from_payload(payload_t).lower() == expected:
                    found = (scan, len(payload_t))
                    break
                scan += 1
            if found is None:
                print(
                    f"error: could not locate height {row['height']} hash {expected[:16]}… in {fn}",
                    file=sys.stderr,
                )
                return 1
            new_off, new_size = found
            old_off, old_size = int(row["file_offset"]), int(row["size"])
            if new_off != old_off or new_size != old_size:
                print(
                    f"fix height={row['height']} {fn} "
                    f"offset {old_off}->{new_off} size {old_size}->{new_size}"
                )
                if not dry_run:
                    conn.execute(
                        "UPDATE blocks SET file_offset = ?, size = ? WHERE height = ?",
                        (new_off, new_size, row["height"]),
                    )
                fixed += 1
            cursor[fn] = new_off + 8 + new_size

        if fixed and not dry_run:
            conn.commit()
        print(f"repaired_rows={fixed} dry_run={dry_run}")
        return 0
    finally:
        for h in handles.values():
            h.close()
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=Path("data/pybitnode.db"))
    parser.add_argument("--blocks-dir", type=Path, default=Path("data/blocks"))
    parser.add_argument("--chain", default="testnet4")
    parser.add_argument(
        "--start-height",
        type=int,
        default=0,
        help="First height to verify (default: validated_height+1 or 1)",
    )
    parser.add_argument("--dry-run", action="store_true")
    ns = parser.parse_args(argv)

    db_path = (_repo_root() / ns.db).resolve() if not ns.db.is_absolute() else ns.db
    blocks_dir = (_repo_root() / ns.blocks_dir).resolve() if not ns.blocks_dir.is_absolute() else ns.blocks_dir
    start = ns.start_height
    if start <= 0:
        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT validated_height FROM chain_state WHERE chain = ?",
            (ns.chain,),
        ).fetchone()
        conn.close()
        validated = int(row[0]) if row else 0
        start = max(1, validated + 1)

    return repair(
        db_path=db_path,
        blocks_dir=blocks_dir,
        chain=ns.chain,
        start_height=start,
        dry_run=ns.dry_run,
    )


if __name__ == "__main__":
    raise SystemExit(main())
