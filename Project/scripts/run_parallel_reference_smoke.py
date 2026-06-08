#!/usr/bin/env python3
"""Compatibility wrapper for the parallel development campaign runner."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


TARGET = Path(__file__).with_name("run_parallel_benchmark_campaign.py")


def main() -> int:
    spec = importlib.util.spec_from_file_location("run_parallel_benchmark_campaign", TARGET)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {TARGET}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return int(module.main())


if __name__ == "__main__":
    sys.exit(main())
