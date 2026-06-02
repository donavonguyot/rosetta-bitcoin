from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from pybitnode.db.tracker import ProjectTracker


def _utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _tick(tracker: ProjectTracker, *, phase: str, runtime_surface: str, process_running: bool) -> dict:
    summary = tracker.summary("testnet4")
    sync = summary.get("sync", {}) if isinstance(summary.get("sync"), dict) else {}
    events = tracker.recent_events(limit=20)
    blocker = ""
    for event in events:
        message = str(event.get("message", ""))
        if "Block connect failed" in message or message in {"Rejected invalid block", "Block unavailable from peers"}:
            blocker = message
            break
    return {
        "captured_at": _utcnow(),
        "phase": phase,
        "runtime_surface": runtime_surface,
        "peer_mode": "none",
        "peer": "",
        "validated_height": int(summary.get("validated_height", 0) or 0),
        "header_height": tracker.max_header_height(),
        "stored_block_height": tracker.max_stored_block_height(),
        "sync_status": str(sync.get("sync_status", "native_ready")),
        "delta_since_last": 0,
        "process_running": process_running,
        "current_blocker": blocker,
        "storage_backend": "rocksdb",
        "full_replay": "out_of_scope",
    }


def _write_tick(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def run(args: argparse.Namespace) -> int:
    tick_path = Path(args.tick_path)
    stop_path = Path(args.stop_path)
    tracker = ProjectTracker(args.state_path)
    try:
        while not stop_path.exists():
            _write_tick(tick_path, _tick(tracker, phase="native_ready", runtime_surface="docker_supervisor", process_running=True))
            time.sleep(max(1, int(args.check_sec)))
        _write_tick(tick_path, _tick(tracker, phase="stopped", runtime_surface="docker_supervisor", process_running=False))
        return 0
    finally:
        tracker.close()


def status(args: argparse.Namespace) -> int:
    tick_path = Path(args.tick_path)
    if not tick_path.exists():
        print("{}")
        return 1
    print(tick_path.read_text().strip())
    return 0


def stop(args: argparse.Namespace) -> int:
    stop_path = Path(args.stop_path)
    stop_path.parent.mkdir(parents=True, exist_ok=True)
    stop_path.write_text(_utcnow() + "\n")
    print(json.dumps({"result": "stop_requested", "stop_path": str(stop_path)}))
    return 0


def resume(args: argparse.Namespace) -> int:
    stop_path = Path(args.stop_path)
    if stop_path.exists():
        stop_path.unlink()
    print(json.dumps({"result": "resume_ready", "stop_path": str(stop_path)}))
    return 0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Bounded Python native Docker supervisor helper.")
    sub = parser.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run")
    run_p.add_argument("--state-path", required=True)
    run_p.add_argument("--tick-path", required=True)
    run_p.add_argument("--stop-path", required=True)
    run_p.add_argument("--check-sec", type=int, default=30)
    run_p.set_defaults(func=run)

    status_p = sub.add_parser("status")
    status_p.add_argument("--tick-path", required=True)
    status_p.set_defaults(func=status)

    stop_p = sub.add_parser("stop")
    stop_p.add_argument("--stop-path", required=True)
    stop_p.set_defaults(func=stop)

    resume_p = sub.add_parser("resume")
    resume_p.add_argument("--stop-path", required=True)
    resume_p.set_defaults(func=resume)

    args = parser.parse_args(argv)
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()
