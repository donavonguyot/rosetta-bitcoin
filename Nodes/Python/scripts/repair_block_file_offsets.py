#!/usr/bin/env python3
"""Repair native block index offsets by scanning blk*.dat files."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

from pybitnode.chain.params import get_chain
from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.storage.blocks import block_hash_hex_from_payload


def _read_block_at(handle, offset: int, magic: bytes) -> tuple[int, bytes] | None:
    handle.seek(offset)
    if handle.read(4) != magic:
        return None
    (payload_size,) = struct.unpack("<I", handle.read(4))
    payload = handle.read(payload_size)
    if len(payload) != payload_size:
        return None
    return 8 + payload_size, payload


def repair(*, state_path: Path, blocks_dir: Path, chain: str, start_height: int, dry_run: bool) -> int:
    params = get_chain(chain)
    tracker = ProjectTracker(state_path)
    handles: dict[str, object] = {}
    try:
        rows = [row for row in tracker.iter_blocks() if int(row["height"]) >= start_height]
        if not rows:
            print(f"no blocks at or above height {start_height}")
            return 0
        cursor: dict[str, int] = {}
        fixed = 0
        for row in rows:
            fn = row["file_name"]
            path = blocks_dir / fn
            if fn not in handles:
                handles[fn] = path.open("rb")
            handle = handles[fn]
            off = cursor.get(fn, int(row["file_offset"]))
            expected = str(row["block_hash"]).lower()
            parsed = _read_block_at(handle, off, params.magic)
            if parsed is None:
                print(f"error: no valid block at {fn}:{off} for height {row['height']}", file=sys.stderr)
                return 1
            span, payload = parsed
            got = block_hash_hex_from_payload(payload).lower()
            if got != expected:
                print(f"error: hash mismatch at height {row['height']}: got={got} expected={expected}", file=sys.stderr)
                return 1
            if int(row["file_offset"]) != off or int(row["size"]) != len(payload):
                print(f"fix height={row['height']} {fn} offset {row['file_offset']}->{off} size {row['size']}->{len(payload)}")
                if not dry_run:
                    tracker.update_block_location(int(row["height"]), file_name=fn, file_offset=off, size=len(payload))
                fixed += 1
            cursor[fn] = off + span
        print(f"fixed={fixed}")
        return 0
    finally:
        for handle in handles.values():
            handle.close()
        tracker.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--blocks-dir", type=Path, default=None)
    parser.add_argument("--chain", default=None)
    parser.add_argument("--start-height", type=int, default=1)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    settings = Settings.from_env()
    if args.state_path:
        settings.state_path = str(args.state_path)
    if args.chain:
        settings.chain = args.chain
    blocks_dir = args.blocks_dir or Path(settings.blocks_dir())
    return repair(
        state_path=Path(settings.resolved_state_path()),
        blocks_dir=blocks_dir,
        chain=settings.chain,
        start_height=args.start_height,
        dry_run=args.dry_run,
    )


if __name__ == "__main__":
    raise SystemExit(main())
