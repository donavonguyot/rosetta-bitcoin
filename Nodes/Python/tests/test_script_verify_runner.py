from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import time

import pytest

from pybitnode.consensus.script import script_verify_runner
from pybitnode.consensus.script.script_verify_runner import (
    InputVerifyTask,
    ScriptVerifyBatchError,
    ScriptVerifyRunner,
    ScriptVerifySettings,
    verify_inputs,
)
from pybitnode.consensus.script.verify import ScriptVerifyError


def _tasks(count: int) -> list[InputVerifyTask]:
    return [
        InputVerifyTask(input_index=index, script_pubkey=b"\x51", amount=1)
        for index in range(count)
    ]


def test_script_verify_runner_uses_sequential_fallback(monkeypatch):
    calls: list[int] = []

    def fake_verify(_tx, input_index, **_kwargs):
        calls.append(input_index)

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)

    elapsed = verify_inputs(
        object(),  # type: ignore[arg-type]
        ((1, b"\x51"),),
        _tasks(2),
        settings=ScriptVerifySettings(parallel_enabled=False, max_threads=4, min_inputs=2),
    )

    assert elapsed >= 0
    assert calls == [0, 1]


def test_script_verify_runner_parallel_success(monkeypatch):
    calls: list[int] = []

    def fake_verify(_tx, input_index, **_kwargs):
        calls.append(input_index)

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)

    elapsed = verify_inputs(
        object(),  # type: ignore[arg-type]
        ((1, b"\x51"),) * 4,
        _tasks(4),
        settings=ScriptVerifySettings(parallel_enabled=True, max_threads=2, min_inputs=2),
    )

    assert elapsed >= 0
    assert sorted(calls) == [0, 1, 2, 3]


def test_script_verify_runner_below_threshold_does_not_create_executor(monkeypatch):
    calls: list[int] = []

    def fake_verify(_tx, input_index, **_kwargs):
        calls.append(input_index)

    def fail_executor(*_args, **_kwargs):
        raise AssertionError("executor should not be created")

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)
    monkeypatch.setattr(script_verify_runner, "ThreadPoolExecutor", fail_executor)

    with ScriptVerifyRunner(settings=ScriptVerifySettings(parallel_enabled=True, max_threads=4, min_inputs=3)) as runner:
        elapsed = runner.verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 2,
            _tasks(2),
        )

    assert elapsed >= 0
    assert calls == [0, 1]


def test_script_verify_runner_reuses_executor_and_closes(monkeypatch):
    calls: list[int] = []
    created: list[ThreadPoolExecutor] = []

    def fake_verify(_tx, input_index, **_kwargs):
        calls.append(input_index)

    def recording_executor(*args, **kwargs):
        executor = ThreadPoolExecutor(*args, **kwargs)
        created.append(executor)
        return executor

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)
    monkeypatch.setattr(script_verify_runner, "ThreadPoolExecutor", recording_executor)

    runner = ScriptVerifyRunner(settings=ScriptVerifySettings(parallel_enabled=True, max_threads=2, min_inputs=2))
    try:
        runner.verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 3,
            _tasks(3),
        )
        runner.verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 3,
            _tasks(3),
        )
    finally:
        runner.close()

    assert len(created) == 1
    assert created[0]._shutdown is True
    assert sorted(calls) == [0, 0, 1, 1, 2, 2]
    with pytest.raises(RuntimeError, match="closed"):
        runner.verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 2,
            _tasks(2),
        )


def test_script_verify_runner_can_select_process_executor(monkeypatch):
    calls: list[int] = []
    created: list[ThreadPoolExecutor] = []

    def fake_verify(_tx, input_index, **_kwargs):
        calls.append(input_index)

    def recording_process_executor(*args, **kwargs):
        executor = ThreadPoolExecutor(*args, **kwargs)
        created.append(executor)
        return executor

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)
    monkeypatch.setattr(script_verify_runner, "ProcessPoolExecutor", recording_process_executor)

    with ScriptVerifyRunner(
        settings=ScriptVerifySettings(
            parallel_enabled=True,
            max_threads=2,
            min_inputs=2,
            executor_kind="process",
        )
    ) as runner:
        runner.verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 2,
            _tasks(2),
        )

    assert len(created) == 1
    assert created[0]._shutdown is True
    assert sorted(calls) == [0, 1]


def test_script_verify_runner_reports_lowest_failing_input(monkeypatch):
    def fake_verify(_tx, input_index, **_kwargs):
        if input_index == 0:
            time.sleep(0.02)
            raise ScriptVerifyError("fail 0")
        if input_index == 2:
            raise ScriptVerifyError("fail 2")

    monkeypatch.setattr(script_verify_runner, "verify_transaction_input", fake_verify)

    with pytest.raises(ScriptVerifyBatchError, match="fail 0"):
        verify_inputs(
            object(),  # type: ignore[arg-type]
            ((1, b"\x51"),) * 3,
            _tasks(3),
            settings=ScriptVerifySettings(parallel_enabled=True, max_threads=3, min_inputs=2),
        )


def test_script_verify_settings_from_env_clamps_values(monkeypatch):
    monkeypatch.setenv("PAR_SCRIPT_VERIFY", "0")
    monkeypatch.setenv("PAR_SCRIPT_THREADS", "0")
    monkeypatch.setenv("PAR_SCRIPT_MIN_INPUTS", "0")
    monkeypatch.setenv("PAR_SCRIPT_EXECUTOR", "process")

    settings = ScriptVerifySettings.from_env()

    assert settings.parallel_enabled is False
    assert settings.max_threads == 1
    assert settings.min_inputs == 1
    assert settings.executor_kind == "process"


def test_script_verify_settings_invalid_executor_falls_back_to_thread():
    settings = ScriptVerifySettings(executor_kind="not-real")

    assert settings.executor_kind == "thread"
