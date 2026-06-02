"""Committed block flat-file fixtures (avoids gitignored data/blocks on CI)."""

from pathlib import Path

FIXTURE_BLOCKS_DIR = Path(__file__).resolve().parent / "fixtures" / "blocks"
