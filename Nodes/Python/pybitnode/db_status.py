"""Inspect pybitnode native RocksDB chainstate."""

from __future__ import annotations

import argparse
import json

from pybitnode.config import Settings
from pybitnode.db.tracker import ProjectTracker
from pybitnode.wire.capabilities import checkpoint_status


def main() -> None:
    parser = argparse.ArgumentParser(description="Show pybitnode native chainstate status")
    parser.add_argument("--chain", default=None)
    parser.add_argument("--state-path", default=None, help="Native RocksDB chainstate directory")
    parser.add_argument("--phases", action="store_true", help="Show roadmap phases only")
    parser.add_argument("--wire", action="store_true", help="Show binary wire capability progress")
    parser.add_argument("--checkpoint", default=None, help="Show capabilities for one checkpoint id")
    parser.add_argument("--events", type=int, default=0, help="Show last N events")
    args = parser.parse_args()

    settings = Settings.from_env()
    if args.chain:
        settings.chain = args.chain
    if args.state_path:
        settings.state_path = args.state_path

    tracker = ProjectTracker(settings.resolved_state_path())
    try:
        if args.wire:
            print(json.dumps(tracker.wire_progress(), indent=2, default=str))
            return
        if args.phases:
            print(json.dumps(list(tracker.list_phases()), indent=2, default=str))
            return
        if args.checkpoint:
            caps = tracker.list_wire_capabilities(args.checkpoint)
            cap_map = tracker.wire_capability_map()
            cp_status = checkpoint_status(cap_map).get(args.checkpoint)
            print(json.dumps({"checkpoint": cp_status, "capabilities": caps}, indent=2, default=str))
            return
        if args.events:
            print(json.dumps(tracker.recent_events(args.events), indent=2, default=str))
            return
        print(json.dumps(tracker.summary(settings.chain), indent=2, default=str))
    finally:
        tracker.close()


if __name__ == "__main__":
    main()
