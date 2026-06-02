from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

from pybitnode.db.tracker import ProjectTracker

_REPO_ROOT = Path(__file__).resolve().parents[1]


def _load_sync_batch_loop():
    path = _REPO_ROOT / "scripts" / "sync_batch_loop.py"
    name = "sync_batch_loop"
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


sbl = _load_sync_batch_loop()


def _seed_datadir(datadir: Path, *, height: int = 100) -> None:
    datadir.mkdir(parents=True, exist_ok=True)
    tracker = ProjectTracker(datadir / "pybitnode.db")
    tracker.set_validated_tip(height, "abcd" * 16, chain="testnet4")
    tracker.close()


def _fake_sync_bin(tmp_path: Path) -> Path:
    sync_bin = tmp_path / "pybitnode-sync"
    sync_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    sync_bin.chmod(0o755)
    return sync_bin


class _FakeProc:
    def __init__(self, *, exit_code: int = 0, output: str = "sync ok\n") -> None:
        self._exit_code = exit_code
        self.stdout = iter([output])

    def wait(self) -> int:
        return self._exit_code


@pytest.fixture
def stall_env(tmp_path: Path):
    datadir = tmp_path / "datadir"
    _seed_datadir(datadir, height=100)
    sync_bin = _fake_sync_bin(tmp_path)
    log_path = tmp_path / "run.log"
    return datadir, sync_bin, log_path


def test_stall_exits_early_on_zero_validated_delta_and_sync_exit_zero(
    stall_env, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
):
    datadir, sync_bin, log_path = stall_env
    popen_calls: list[int] = []

    def fake_popen(*args, **kwargs):
        popen_calls.append(1)
        return _FakeProc()

    monkeypatch.setattr(subprocess, "Popen", fake_popen)

    rc = sbl.main(
        [
            "--datadir",
            str(datadir),
            "--target",
            "10000",
            "--sync",
            str(sync_bin),
            "--log",
            str(log_path),
            "--max-batches",
            "5",
        ]
    )

    assert rc == 5
    assert len(popen_calls) == 1
    out = capsys.readouterr()
    assert "=== STALL validated_delta=0 exit=0 batch=1" in out.out
    assert "consensus stall?" in out.err
    log_text = log_path.read_text(encoding="utf-8")
    assert "=== STALL validated_delta=0 exit=0 batch=1" in log_text


def test_zero_delta_with_nonzero_sync_exit_continues(
    stall_env, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
):
    datadir, sync_bin, log_path = stall_env
    popen_calls: list[int] = []

    def fake_popen(*args, **kwargs):
        popen_calls.append(1)
        return _FakeProc(exit_code=1)

    monkeypatch.setattr(subprocess, "Popen", fake_popen)

    rc = sbl.main(
        [
            "--datadir",
            str(datadir),
            "--target",
            "10000",
            "--sync",
            str(sync_bin),
            "--log",
            str(log_path),
            "--max-batches",
            "2",
        ]
    )

    assert rc == 4
    assert len(popen_calls) == 2
    out = capsys.readouterr()
    assert "STALL" not in out.out


def test_progress_continues_when_validated_delta_positive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
):
    datadir = tmp_path / "datadir"
    _seed_datadir(datadir, height=100)
    sync_bin = _fake_sync_bin(tmp_path)
    log_path = tmp_path / "run.log"
    height_calls = iter([100, 300, 300, 300])

    def fake_validated_height(spr_mod, *, datadir: Path, chain: str) -> int:
        return next(height_calls)

    monkeypatch.setattr(sbl, "_validated_height", fake_validated_height)

    popen_calls: list[int] = []

    def fake_popen(*args, **kwargs):
        popen_calls.append(1)
        return _FakeProc()

    monkeypatch.setattr(subprocess, "Popen", fake_popen)

    rc = sbl.main(
        [
            "--datadir",
            str(datadir),
            "--target",
            "10000",
            "--sync",
            str(sync_bin),
            "--log",
            str(log_path),
            "--max-batches",
            "5",
        ]
    )

    assert rc == 5
    assert len(popen_calls) == 2
    out = capsys.readouterr()
    assert "validated_delta=200" in out.out
    assert "=== STALL validated_delta=0 exit=0 batch=2" in out.out
