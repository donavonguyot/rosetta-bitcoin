from __future__ import annotations

import os
from concurrent.futures import Executor, ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from time import perf_counter
from typing import Sequence

from pybitnode.consensus.script.verify import ScriptVerifyError, verify_transaction_input
from pybitnode.messages.transaction import Transaction


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return int(raw)


@dataclass(frozen=True)
class ScriptVerifySettings:
    parallel_enabled: bool = True
    max_threads: int = os.cpu_count() or 1
    min_inputs: int = 2
    executor_kind: str = "thread"

    def __post_init__(self) -> None:
        object.__setattr__(self, "max_threads", max(1, int(self.max_threads)))
        object.__setattr__(self, "min_inputs", max(1, int(self.min_inputs)))
        executor_kind = self.executor_kind.strip().lower()
        if executor_kind not in {"thread", "process"}:
            executor_kind = "thread"
        object.__setattr__(self, "executor_kind", executor_kind)

    @classmethod
    def from_env(cls) -> ScriptVerifySettings:
        return cls(
            parallel_enabled=_env_bool("PAR_SCRIPT_VERIFY", True),
            max_threads=_env_int("PAR_SCRIPT_THREADS", os.cpu_count() or 1),
            min_inputs=_env_int("PAR_SCRIPT_MIN_INPUTS", 2),
            executor_kind=os.environ.get("PAR_SCRIPT_EXECUTOR", "thread"),
        )


@dataclass(frozen=True)
class InputVerifyTask:
    input_index: int
    script_pubkey: bytes
    amount: int


class ScriptVerifyBatchError(ScriptVerifyError):
    def __init__(self, message: str, *, elapsed_seconds: float) -> None:
        super().__init__(message)
        self.elapsed_seconds = elapsed_seconds


def _verify_one(
    transaction: Transaction,
    spent_prevouts: Sequence[tuple[int, bytes]],
    task: InputVerifyTask,
) -> tuple[int, str | None, float]:
    started = perf_counter()
    try:
        verify_transaction_input(
            transaction,
            task.input_index,
            script_pubkey=task.script_pubkey,
            amount=task.amount,
            spent_prevouts=spent_prevouts,
        )
        return task.input_index, None, perf_counter() - started
    except ScriptVerifyError as exc:
        return task.input_index, str(exc), perf_counter() - started


def verify_inputs(
    transaction: Transaction,
    spent_prevouts: Sequence[tuple[int, bytes]],
    tasks: Sequence[InputVerifyTask],
    *,
    settings: ScriptVerifySettings | None = None,
) -> float:
    with ScriptVerifyRunner(settings=settings) as runner:
        return runner.verify_inputs(transaction, spent_prevouts, tasks)


class ScriptVerifyRunner:
    def __init__(self, *, settings: ScriptVerifySettings | None = None) -> None:
        self.settings = settings or ScriptVerifySettings.from_env()
        self._executor: Executor | None = None
        self._closed = False

    def __enter__(self) -> ScriptVerifyRunner:
        return self

    def __exit__(self, _exc_type, _exc, _tb) -> None:
        self.close()

    def close(self) -> None:
        self._closed = True
        if self._executor is not None:
            self._executor.shutdown(wait=True, cancel_futures=False)
            self._executor = None

    def verify_inputs(
        self,
        transaction: Transaction,
        spent_prevouts: Sequence[tuple[int, bytes]],
        tasks: Sequence[InputVerifyTask],
    ) -> float:
        if self._closed:
            raise RuntimeError("script verify runner is closed")
        return _verify_inputs_with_runner(transaction, spent_prevouts, tasks, self)

    def _executor_for_parallel_verify(self) -> Executor:
        if self._executor is None:
            executor_cls = ProcessPoolExecutor if self.settings.executor_kind == "process" else ThreadPoolExecutor
            self._executor = executor_cls(max_workers=self.settings.max_threads)
        return self._executor


def _verify_inputs_with_runner(
    transaction: Transaction,
    spent_prevouts: Sequence[tuple[int, bytes]],
    tasks: Sequence[InputVerifyTask],
    runner: ScriptVerifyRunner,
) -> float:
    """Verify transaction inputs and return summed verifier elapsed seconds.

    The parallel path intentionally only covers independent input script checks.
    Prevout loading and UTXO mutation stay in the caller's sequential block
    connect path.
    """
    if not tasks:
        return 0.0
    settings = runner.settings
    if not settings.parallel_enabled or len(tasks) < settings.min_inputs:
        failures: list[tuple[int, str]] = []
        elapsed = 0.0
        for task in tasks:
            input_index, error, spent = _verify_one(transaction, spent_prevouts, task)
            elapsed += spent
            if error is not None:
                failures.append((input_index, error))
        if failures:
            failures.sort(key=lambda item: item[0])
            raise ScriptVerifyBatchError(failures[0][1], elapsed_seconds=elapsed)
        return elapsed

    failures: list[tuple[int, str]] = []
    elapsed = 0.0
    executor = runner._executor_for_parallel_verify()
    futures = [
        executor.submit(_verify_one, transaction, spent_prevouts, task)
        for task in tasks
    ]
    for future in as_completed(futures):
        input_index, error, spent = future.result()
        elapsed += spent
        if error is not None:
            failures.append((input_index, error))

    if failures:
        failures.sort(key=lambda item: item[0])
        raise ScriptVerifyBatchError(failures[0][1], elapsed_seconds=elapsed)
    return elapsed
