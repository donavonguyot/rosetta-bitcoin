from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest
import sqlite_utils

from pybitnode.db.schema import init_schema
from pybitnode.db.tracker import ProjectTracker

_REPO_ROOT = Path(__file__).resolve().parents[1]


def _load_script_module():
    path = _REPO_ROOT / "scripts" / "sync_progress_report.py"
    name = "sync_progress_report"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


spr = _load_script_module()


def test_parse_batch_log_and_in_progress_height():
    lines = [
        "noise",
        "=== batch 1 start_validated=4800 2026-05-25T00:00:00Z ===",
        "=== batch 1 end_validated=5000 downloaded_delta=200 exit=0 "
        "(2026-05-25T00:10:00Z) validated_delta=200 ===",
        "=== batch 2 start_validated=5000 2026-05-25T00:10:00Z ===",
    ]
    last_start, last_end = spr.parse_batch_log_lines(lines)
    assert last_start is not None and last_start.start_validated == 5000
    assert last_end is not None and last_end.end_validated == 5000
    assert spr.validated_height_from_log(last_start, last_end) == 5000

    lines_with_end = lines + [
        "=== batch 2 end_validated=5200 downloaded_delta=200 exit=0 "
        "(2026-05-25T00:20:00Z) validated_delta=200 ===",
    ]
    last_start, last_end = spr.parse_batch_log_lines(lines_with_end)
    assert last_end.end_validated == 5200
    assert spr.validated_height_from_log(last_start, last_end) == 5200


def test_build_report_uses_db_height(tmp_path):
    log = tmp_path / "run.log"
    log.write_text(
        "=== batch 1 start_validated=1 2026-05-25T00:00:00Z ===\n"
        "=== batch 1 end_validated=9999 downloaded_delta=9998 exit=0 "
        "(2026-05-25T00:30:00Z) validated_delta=9998 ===\n",
        encoding="utf-8",
    )
    db_path = tmp_path / "db.sqlite"
    tracker = ProjectTracker(db_path)
    tracker.set_validated_tip(100, "abcd" * 16, chain="testnet4")
    tracker.close()

    lines = spr.build_report(log_path=log, target=10_000, db_path=db_path, chain="testnet4")
    assert "validated_height=100" in lines
    assert "pct_to_target=1.0%" in lines
    assert "last_batch_validated_delta=9998" in lines
    assert "last_batch_timestamp=2026-05-25T00:30:00Z" in lines


def test_pct_to_target_caps():
    assert spr.pct_to_target(20_000, 10_000) == 100.0


@pytest.mark.parametrize(
    "fixture,msg",
    [
        ("", "No batch start/end"),
        ("=== not a batch line ===", "No batch start/end"),
    ],
)
def test_build_report_errors_on_empty_log(tmp_path, fixture: str, msg: str):
    log = tmp_path / "empty.log"
    log.write_text(fixture, encoding="utf-8")
    with pytest.raises(ValueError, match="No batch start/end"):
        spr.build_report(log_path=log, target=10_000, db_path=None, chain="testnet4")


def test_read_validated_height_db_missing_chain_returns_zero(tmp_path):
    db_path = tmp_path / "empty.sqlite"
    raw = sqlite_utils.Database(str(db_path))
    init_schema(raw)
    raw.close()
    assert spr.read_validated_height_db(db_path, chain="testnet4") == 0


def test_read_validated_height_db_missing_file_returns_zero(tmp_path):
    missing = tmp_path / "nosuch.sqlite"
    assert spr.read_validated_height_db(missing, chain="testnet4") == 0


def test_sqlite_readonly_uri_includes_mode_ro():
    uri = spr.sqlite_readonly_uri(Path("/tmp/demo.sqlite"))
    assert "mode=ro" in uri
    assert uri.startswith("file:")


def test_read_validated_height_db_opens_via_readonly_uri(tmp_path, monkeypatch):
    import sqlite3 as sqlite3_mod

    db_path = tmp_path / "t.sqlite"
    raw = sqlite_utils.Database(str(db_path))
    init_schema(raw)
    raw.close()

    captured: list[tuple[tuple[object, ...], dict[str, object]]] = []
    real_connect = sqlite3_mod.connect

    def _capture(*args: object, **kwargs: object):
        captured.append((args, kwargs))
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3_mod, "connect", _capture)
    spr.read_validated_height_db(db_path, chain="testnet4")
    assert captured, "sqlite3.connect was not invoked"
    first_uri = captured[0][0][0]
    assert isinstance(first_uri, str)
    assert "mode=ro" in first_uri
    assert captured[0][1].get("uri") is True
